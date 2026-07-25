# frozen_string_literal: true

module Agentkit
  module Cognition
    module Processors
      class Base
        attr_reader :options, :context, :trace

        def initialize(options:, context:, trace:)
          @options = options
          @context = context
          @trace   = trace
        end

        def call(dry_run: false) = raise NotImplementedError

        private

        def config    = context.config.memory
        def scope     = normalize_scope(options[:scope])
        def dry?(flag) = flag || options[:dry_run]

        def normalize_scope(raw)
          return { tenant_key: context.tenant_key }.compact if raw.nil?
          return raw.call(context) if raw.respond_to?(:call)

          out = raw.dup
          out[:account_id] ||= out.delete(:account)&.then { |a| a.respond_to?(:id) ? a.id : a }
          out[:tenant_key] ||= context.tenant_key
          out.compact
        end

        def chat(prompt, model: :default, temperature: nil, schema: nil, system: nil)
          LLM.complete(prompt, model: model, temperature: temperature, schema: schema,
                               system: system, agent: self.class.name)
        end

        def finish(status: "completed", **data)
          trace.complete!(status: status, **data)
          Cognition.record_trace(trace)
          trace
        end
      end

      # ─── Dreaming ────────────────────────────────────────────────────────────

      # On-demand, configurable, non-destructive consolidation.
      #
      # Three changes from v0.1: cron is only one trigger, `dry_run` returns the
      # plan without writing anything, and sources are marked `superseded`
      # instead of being blindly archived (`update_all(status: "archived")` was
      # irreversible and cost the embeddings of everything it archived).
      class Dreaming < Base
        def call(dry_run: false)
          dry       = dry?(dry_run)
          strategy  = options[:strategy] || config.dreaming.clustering
          memories  = candidates
          trace.phase(:load, count: memories.size, strategy: strategy)

          return finish(status: "skipped", reason: "insufficient_memories", clusters: 0) if memories.size < min_cluster

          clusters = cluster(memories, strategy)
          clusters = clusters.select { |c| c.size >= min_cluster }
          clusters = clusters.select { |c| options[:gate].call(c) } if options[:gate]
          trace.phase(:cluster, clusters: clusters.size,
                                sizes: clusters.map(&:size))

          if dry
            plan = clusters.map { |c| { size: c.size, sources: c.map(&:id), preview: c.first.content.to_s[0, 120] } }
            return finish(status: "dry_run", clusters: clusters.size, plan: plan)
          end

          insights = clusters.map { |c| consolidate(c) }
          finish(clusters: clusters.size, insights: insights.compact.size)
        end

        private

        def min_cluster = options[:min_cluster] || config.dreaming.min_cluster

        def candidates
          pool = Memory.all(scope.merge(status: %w[raw embedded], ontological: %w[real]))
          pool = pool.reject(&:superseded?)
          min_recalls = options[:min_recalls] || config.dreaming.min_recalls
          # Cooldown: a memory nobody ever recalled is not evidence of a pattern.
          pool.select { |m| m.recall_count.to_i >= min_recalls || m.importance.to_f >= 0.8 }
              .then { |list| list.empty? ? pool : list }
        end

        # `:batch_embed` vectorises the whole window in ONE provider call and
        # then clusters. `:lexical` needs no embeddings at all.
        def cluster(memories, strategy)
          case strategy.to_sym
          when :lexical then cluster_lexical(memories)
          when :llm     then cluster_llm(memories)
          else               cluster_vectors(memories)
          end
        end

        def cluster_vectors(memories)
          missing = memories.reject(&:embedded?)
          if missing.any?
            trace.phase(:batch_embed, count: missing.size)
            Memory.embedder.embed_records(missing, config)
          end
          embedded = memories.select(&:embedded?)
          greedy(embedded) { |a, b| cosine(a.embedding, b.embedding) }
        end

        def cluster_lexical(memories)
          greedy(memories) { |a, b| 1.0 - jaccard(tokens(a), tokens(b)) }
        end

        def cluster_llm(memories)
          window = memories.first(40)
          schema = LLM::Schema.define { array :groups, min_items: 1 }
          listing = window.map.with_index(1) { |m, i| "#{i}. #{m.content}" }.join("\n")
          response = chat(<<~PROMPT, model: options[:model] || :fast, schema: schema)
            Group these observations by topic. Return {"groups": [[1,3],[2,5,6]]}
            using the item numbers. Only group items that share a real theme.

            #{listing}
          PROMPT
          Array(response.parsed&.dig(:groups)).map { |g| Array(g).filter_map { |i| window[i.to_i - 1] } }
        rescue StandardError
          cluster_lexical(memories)
        end

        def greedy(items)
          threshold = options[:threshold] || config.dreaming.threshold
          clusters  = []
          assigned  = {}
          items.each_with_index do |item, i|
            next if assigned[i]

            group = [item]
            assigned[i] = true
            items.each_with_index do |other, j|
              next if j <= i || assigned[j]
              next unless yield(item, other) < threshold

              group << other
              assigned[j] = true
            end
            clusters << group
          end
          clusters
        end

        def consolidate(cluster)
          block = cluster.map.with_index(1) { |m, i| "[#{i}] #{m.content}" }.join("\n")
          synthesis = chat(<<~PROMPT, model: options[:model] || :default).content
            Synthesize these #{cluster.size} related observations into one
            higher-level insight. Be concise (2-4 sentences). Output only the
            insight text.

            #{block}
          PROMPT

          insight = Memory.store(
            synthesis,
            source_agent: "Agentkit::Cognition::Dreaming",
            tags: cluster.flat_map(&:tags).uniq + ["consolidated"],
            type: "insight",
            confidence: [(cluster.sum { |m| m.confidence.to_f } / cluster.size) + 0.05, 1.0].min,
            importance: 0.85,
            # No forced embedding: under :on_promotion an insight is promoted by
            # type anyway, and under :never the operator meant never.
            embed: options[:embed],
            context: context
          )
          Memory.supersede!(cluster, by: insight) if options.fetch(:supersede, config.dreaming.supersede_sources)
          trace.phase(:consolidated, cluster: cluster.map(&:id), insight: insight.id)
          insight
        end

        def tokens(memory) = memory.content.to_s.downcase.scan(/[[:alnum:]]{4,}/).uniq

        def jaccard(a, b)
          return 0.0 if a.empty? || b.empty?

          (a & b).size.to_f / (a | b).size
        end

        def cosine(a, b)
          return 1.0 if a.nil? || b.nil?

          dot = na = nb = 0.0
          a.each_with_index { |x, i| y = b[i].to_f; dot += x * y; na += x * x; nb += y * y }
          return 1.0 if na.zero? || nb.zero?

          1.0 - (dot / (Math.sqrt(na) * Math.sqrt(nb)))
        end
      end

      # ─── Summarizer ──────────────────────────────────────────────────────────

      # On-demand summaries over any source. MaaS's "summary" endpoint was a
      # `SELECT ... ORDER BY importance` in disguise; this is a real processor
      # with token budgeting, tree reduction and a content-hash cache, so asking
      # for the same summary twice does not cost twice.
      class Summarizer < Base
        STRATEGIES = %i[stuff map_reduce refine hierarchical extractive].freeze

        def call(dry_run: false)
          items    = load_source
          strategy = (options[:strategy] || auto_strategy(items)).to_sym
          trace.phase(:load, items: items.size, strategy: strategy)

          return finish(status: "skipped", reason: "empty_source") if items.empty?

          key = cache_key(items, strategy)
          if options.fetch(:cache, true) && (hit = self.class.cache[key])
            trace.phase(:cache_hit)
            finish(cached: true, chars: hit.to_s.length)
            return hit
          end

          if dry?(dry_run)
            finish(status: "dry_run", items: items.size, chunks: chunks_for(items).size)
            return nil
          end

          text = case strategy
                 when :stuff        then summarize_stuff(items)
                 when :refine       then summarize_refine(items)
                 when :extractive   then summarize_extractive(items)
                 when :hierarchical then summarize_tree(items, levels: true)
                 else                    summarize_tree(items)
                 end

          self.class.cache[key] = text
          persist(text)
          finish(items: items.size, chars: text.to_s.length)
          text
        end

        def self.cache = @cache ||= {}

        private

        def load_source
          src = options[:source]
          return Memory.all(scope) if src.nil?
          return src.call(context) if src.respond_to?(:call)
          return Array(src) if src.is_a?(Array)
          return src.to_a if src.respond_to?(:to_a)

          [src]
        end

        def auto_strategy(items)
          total = items.sum { |i| text_of(i).length }
          return :stuff if total < 6_000
          return :map_reduce if total < 200_000

          :hierarchical
        end

        def budget = options[:budget] || { input_tokens: 60_000, output_tokens: 800 }

        def chunks_for(items)
          max_chars = (budget[:input_tokens] || 60_000) * 4 / 8
          chunks = []
          current = +""
          items.each do |item|
            piece = text_of(item)
            if current.length + piece.length > max_chars && !current.empty?
              chunks << current
              current = +""
            end
            current << piece << "\n"
          end
          chunks << current unless current.strip.empty?
          chunks
        end

        def summarize_stuff(items)
          chat(instruction(items.map { |i| text_of(i) }.join("\n")), model: options[:model] || :default).content
        end

        # Map/reduce with a tree reduction — the same shape the Flow engine's
        # map/reduce nodes provide when this runs inside a flow.
        def summarize_tree(items, levels: false)
          partials = chunks_for(items).map do |chunk|
            chat("Summarize this fragment in 3-5 bullet points:\n\n#{chunk}", model: options[:model] || :fast).content
          end
          trace.phase(:map, chunks: partials.size)

          while partials.size > 1
            partials = partials.each_slice(levels ? 3 : 5).map do |group|
              chat("Merge these partial summaries into one, removing redundancy:\n\n#{group.join("\n\n")}",
                   model: options[:model] || :default).content
            end
            trace.phase(:reduce, remaining: partials.size)
          end
          chat(instruction(partials.first), model: options[:model] || :default).content
        end

        def summarize_refine(items)
          chunks_for(items).reduce(nil) do |acc, chunk|
            prompt = acc.nil? ? "Summarize:\n\n#{chunk}" : "Refine this summary with new material.\n\nSummary:\n#{acc}\n\nNew:\n#{chunk}"
            chat(prompt, model: options[:model] || :default).content
          end
        end

        # No LLM at all: rank sentences by term frequency. The cheapest rung of
        # the ladder, useful when the budget is spent.
        def summarize_extractive(items)
          sentences = items.flat_map { |i| text_of(i).split(/(?<=[.!?])\s+/) }
          freq = Hash.new(0)
          sentences.each { |s| s.downcase.scan(/[[:alnum:]]{4,}/).each { |w| freq[w] += 1 } }
          sentences.sort_by { |s| -s.downcase.scan(/[[:alnum:]]{4,}/).sum { |w| freq[w] } }
                   .first(options[:max_sentences] || 5)
                   .join(" ")
        end

        def instruction(body)
          audience = options[:audience]
          format   = options[:format] || :bullets
          shape = case format.to_sym
                  when :exec     then "an executive summary in 3 short paragraphs"
                  when :timeline then "a chronological timeline of the key events"
                  when :json     then "a JSON object with keys: headline, key_points, risks"
                  else                "5-8 concise bullet points"
                  end
          <<~PROMPT
            Produce #{shape}#{audience ? " for a #{audience}" : ''}.
            Be specific; keep numbers and names. No preamble.

            #{body}
          PROMPT
        end

        def persist(text)
          opts = options[:persist]
          return if opts == false || opts.nil?

          opts = {} unless opts.is_a?(Hash)
          if opts.fetch(:memory, true)
            Memory.store(text, source_agent: "Agentkit::Cognition::Summarizer",
                               type: "summary", ontological_type: "summary",
                               importance: 0.75, tags: Array(options[:tags]),
                               embed: opts[:embed], context: context)
          end
          trace.phase(:persisted)
        end

        def cache_key(items, strategy)
          digest = Digest::SHA256.hexdigest(items.map { |i| text_of(i) }.join("|"))[0, 24]
          "#{digest}:#{strategy}:#{options[:format]}:#{options[:model]}"
        end

        def text_of(item)
          return item if item.is_a?(String)
          return item.content.to_s if item.respond_to?(:content)
          return item.body.to_s if item.respond_to?(:body)

          item.to_s
        end
      end

      # ─── Imagination ─────────────────────────────────────────────────────────

      # Three-phase divergent pipeline (extraction → incubation → verification)
      # with a local backend, so it works in apps that have no MaaS deployment —
      # five of the six v0.1 projects did not.
      #
      # Everything is per-call configurable, not just global config, and the
      # ontological firewall lives in the kernel: scenarios are stored with
      # `ontological_type: "imagined"` and never come back from a normal recall.
      class Imagination < Base
        DIVERGENCE_STRATEGIES = %i[max_semantic_spread cross_agent cross_role temporal_contrast random_walk].freeze

        def call(dry_run: false)
          backend = options[:backend] || config.imagination.backend
          return delegate_to_maas if backend.to_sym == :maas

          sources = extract
          trace.phase(:divergent_extraction, sources: sources.size,
                                             ids: sources.map(&:id),
                                             strategy: divergence_strategy)
          return finish(status: "skipped", reason: "insufficient_sources") if sources.size < min_sources

          return finish(status: "dry_run", sources: sources.size) if dry?(dry_run)

          ideas = incubate(sources)
          trace.phase(:incubation, generated: ideas.size, temperature: incubate_temp)

          viable = ideas.select { |i| i[:originality].to_f >= gates[:originality] }
          trace.phase(:practicality_gate, kept: viable.size, dropped: ideas.size - viable.size)

          scenarios = viable.filter_map { |idea| verify(idea, sources) }
          persisted = scenarios.select { |s| passes_final_gate?(s) }
          trace.phase(:verification, verified: scenarios.size, persisted: persisted.size)

          records = persisted.map { |s| persist_scenario(s, sources) }
          finish(sources: sources.size, ideas: ideas.size, scenarios: records.size)
          records
        end

        private

        def gates
          defaults = config.imagination.gates
          (options[:gates] || {}).then { |o| defaults.merge(o.transform_keys(&:to_sym)) }
        end

        def min_sources    = options[:min_sources] || config.imagination.min_sources
        def max_sources    = options[:max_sources] || config.imagination.max_sources
        def incubate_temp  = options.dig(:incubate, :temperature) || config.imagination.incubate_temperature
        def verify_temp    = options.dig(:verify, :temperature) || config.imagination.verify_temperature
        def divergence_strategy = options.dig(:divergence, :strategy) || :max_semantic_spread

        # Phase 1 — deliberately anti-clustering: pick memories that are far
        # apart, not close together.
        def extract
          pool = Memory.all(scope.merge(ontological: %w[real])).reject(&:superseded?)
          pool = pool.select { |m| m.content.to_s.length > 20 }
          return [] if pool.size < min_sources

          case divergence_strategy.to_sym
          when :cross_agent      then spread_by(pool, :source_agent)
          when :cross_role       then spread_by(pool, :role)
          when :temporal_contrast then temporal(pool)
          when :random_walk      then pool.sample(max_sources)
          else                        semantic_spread(pool)
          end
        end

        def spread_by(pool, attribute)
          pool.group_by { |m| m.public_send(attribute) }.values.map(&:sample).compact.first(max_sources)
        end

        def temporal(pool)
          sorted = pool.sort_by(&:created_at)
          half   = [sorted.size / 2, 1].max
          (sorted.first(half).sample(max_sources / 2) + sorted.last(half).sample(max_sources / 2)).compact
        end

        # Maximum semantic spread: greedily add the memory farthest from those
        # already chosen. Falls back to tag diversity when there are no vectors,
        # so imagination works at `level: :keyword` too.
        def semantic_spread(pool)
          embedded = pool.select(&:embedded?)
          return diverse_by_tags(pool) if embedded.size < min_sources

          chosen = [embedded.sample]
          while chosen.size < max_sources && chosen.size < embedded.size
            candidate = (embedded - chosen).max_by do |m|
              chosen.map { |c| distance(m.embedding, c.embedding) }.min
            end
            break if candidate.nil?

            chosen << candidate
          end
          threshold = options.dig(:divergence, :threshold) || config.imagination.divergence
          chosen.select { |m| chosen.all? { |o| o.equal?(m) || distance(m.embedding, o.embedding) >= threshold * 0.5 } }
                .then { |list| list.size >= min_sources ? list : chosen }
        end

        def diverse_by_tags(pool)
          pool.group_by { |m| m.tags.first }.values.map(&:first).compact.first(max_sources)
        end

        # Phase 2 — Default Mode Network: high temperature, no censorship.
        def incubate(sources)
          schema = LLM::Schema.define do
            array :ideas, min_items: 1
          end
          block = sources.map.with_index(1) { |m, i| "[#{i}] #{m.content}" }.join("\n")
          response = chat(<<~PROMPT, model: options.dig(:incubate, :model) || :complex, temperature: incubate_temp, schema: schema)
            You are free-associating. Combine these unrelated fragments into
            #{min_ideas}-#{max_ideas} NEW hypothetical ideas that none of them
            implies alone. Do not summarize them. Favour unexpected connections.

            #{block}

            Return {"ideas": [{"concept": "...", "description": "...", "originality": 0.0-1.0}]}
          PROMPT

          Array(response.parsed&.dig(:ideas)).map { |i| symbolize(i) }
        rescue SchemaViolation => e
          trace.phase(:incubation_failed, error: e.message)
          []
        end

        # Phase 3 — Executive Control: low temperature, structured, scored.
        def verify(idea, sources)
          schema = LLM::Schema.define do
            string :practical_application, required: true, min_length: 20
            number :innovation_score, required: true, min: 0, max: 1
            number :relevance_score,  required: true, min: 0, max: 1
            number :confidence,       required: true, min: 0, max: 1
          end
          response = chat(<<~PROMPT, model: options.dig(:verify, :model) || :default, temperature: verify_temp, schema: schema)
            Evaluate this hypothetical idea for #{Agentkit.config.domain_name}.

            Concept: #{idea[:concept]}
            Description: #{idea[:description]}
            Grounded in #{sources.size} observations.

            Give a concrete practical application, and score innovation,
            relevance to the domain, and your confidence.
          PROMPT

          response.parsed&.merge(concept: idea[:concept], originality: idea[:originality])
        rescue SchemaViolation
          nil
        end

        def passes_final_gate?(scenario)
          g = gates
          scenario[:innovation_score].to_f >= g[:innovation] &&
            scenario[:relevance_score].to_f >= g[:relevance] &&
            scenario[:confidence].to_f >= g[:confidence]
        end

        # Stored as `imagined`, which the recall scope excludes by default.
        # A hypothesis can never be mistaken for a verified fact.
        def persist_scenario(scenario, sources)
          record = Memory.store(
            "#{scenario[:concept]}\n\n#{scenario[:practical_application]}",
            source_agent: "Agentkit::Cognition::Imagination",
            type: "scenario", ontological_type: "imagined",
            confidence: scenario[:confidence], importance: scenario[:innovation_score],
            tags: Array(options[:tags]) + ["imagined"],
            ttl: options[:ttl] || config.imagination.ttl,
            embed: options[:embed],
            metadata: {
              "innovation_score" => scenario[:innovation_score],
              "relevance_score"  => scenario[:relevance_score],
              "originality"      => scenario[:originality],
              "source_memory_ids" => sources.map(&:id),
              "trace_id"         => trace.id
            },
            context: context
          )
          suggest(record, scenario) if options.dig(:output, :suggestion)
          record
        end

        def suggest(record, scenario)
          HITL.suggest!(
            type: "creative_insight",
            title: "Insight creativo: #{scenario[:concept].to_s[0, 60]}",
            description: "[ESCENARIO HIPOTÉTICO — no es un hecho verificado]\n\n" \
                         "#{scenario[:practical_application]}",
            priority: scenario[:innovation_score].to_f >= 0.85 ? "high" : "medium",
            source_agent: "Agentkit::Cognition::Imagination",
            payload: { "memory_id" => record.id, "ontological_type" => "imagined" }
                     .merge(record.metadata),
            context: context
          )
        end

        def delegate_to_maas
          client = options[:client] || Agentkit.config.chat[:maas_client]
          raise ConfigurationError, "backend :maas needs a client" if client.nil?

          scenarios = client.imagine(scope: scope, focus: options[:focus])
          finish(sources: 0, scenarios: Array(scenarios).size, backend: "maas")
          scenarios
        end

        def min_ideas = options.dig(:incubate, :ideas)&.first || config.imagination.min_ideas
        def max_ideas = options.dig(:incubate, :ideas)&.last  || config.imagination.max_ideas

        def distance(a, b)
          return 1.0 if a.nil? || b.nil?

          dot = na = nb = 0.0
          a.each_with_index { |x, i| y = b[i].to_f; dot += x * y; na += x * x; nb += y * y }
          return 1.0 if na.zero? || nb.zero?

          1.0 - (dot / (Math.sqrt(na) * Math.sqrt(nb)))
        end

        def symbolize(hash) = hash.transform_keys(&:to_sym)
      end
    end
  end
end
