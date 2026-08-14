# frozen_string_literal: true

require_relative "memory/record"
require_relative "memory/policy"
require_relative "memory/stores"
require_relative "memory/embedder"

module Agentkit
  # Semantic memory with on-demand, configurable vectorisation.
  #
  #   Agentkit::Memory.store("Acme paid 15 days late", tags: %w[payment acme])
  #   Agentkit::Memory.recall("late payers", mode: :keyword)   # 0 API calls
  #   Agentkit::Memory.estimate_embedding_cost(policy: :on_promotion)
  module Memory
    class << self
      def store_backend
        @store_backend ||= Stores.build(Agentkit.config.memory.store)
      end

      attr_writer :store_backend

      def embedder
        @embedder ||= Embedder.new(store: store_backend)
      end

      def reset!
        @store_backend = nil
        @embedder      = nil
        self
      end

      # ─── Write ───────────────────────────────────────────────────────────────

      # @param embed [Symbol, Boolean, nil] per-call override of the embedding
      #   policy — the most specific of the four configuration levels.
      def store(content, source_agent: nil, tags: [], type: "observation", confidence: 0.7,
                importance: nil, role: nil, derived_from: nil, canonical: nil,
                ontological_type: "real", ttl: nil, embed: nil, metadata: {}, context: nil)
        ctx    = context || Context.resolve
        config = ctx.config.memory
        return nil unless config.writes?

        record = Record.new(
          content: content.to_s, memory_type: type.to_s, tags: Array(tags).map(&:to_s),
          confidence: confidence, importance: importance || default_importance(type),
          role: role&.to_s, source_agent: source_agent, ontological_type: ontological_type.to_s,
          derived_from_memory_id: derived_from, canonical_memory_id: canonical,
          user_id: id_of(ctx.user), account_id: id_of(ctx.account), tenant_key: ctx.tenant_key,
          run_id: ctx.run_id, expires_at: ttl ? Time.now + ttl : nil, metadata: metadata
        )
        store_backend.insert(record)

        decision = Policy.decide(record, config, override: embed)
        embedder.apply(record, decision, config)

        Telemetry.emit("memory.write",
                       dims: { agent: source_agent, type: type.to_s, policy: config.embedding.policy,
                               decision: decision, ontological: ontological_type.to_s },
                       measures: { bytes: content.to_s.bytesize, embedded: decision == :now })
        record
      end

      # Mark a memory as promoted. Under `:on_promotion` this is what actually
      # buys the vector — and it is called by the dreaming consolidation, by
      # repeated recalls, and by domain code that knows something matters.
      def promote!(record, reason: nil, context: nil)
        config = (context || Context.resolve).config.memory
        record.promoted_at = Time.now
        store_backend.update(record.id, promoted_at: record.promoted_at)
        embedder.apply(record, Policy.decide(record, config, override: :batch), config) unless record.embedded?
        Telemetry.emit("memory.promoted", dims: { reason: reason, type: record.memory_type })
        record
      end

      # Non-destructive consolidation: the sources are marked superseded, never
      # deleted or blindly archived, so a bad dreaming cycle can be rolled back.
      def supersede!(sources, by:, context: nil)
        Array(sources).each do |src|
          store_backend.update(src.id, superseded_by_id: by.id, status: "superseded")
          src.superseded_by_id = by.id
          src.status = "superseded"
        end
        Telemetry.emit("memory.superseded", measures: { count: Array(sources).size })
        by
      end

      def rollback_supersede!(by_id)
        restored = store_backend.all.select { |r| r.superseded_by_id == by_id }
        restored.each do |r|
          store_backend.update(r.id, superseded_by_id: nil, status: r.embedded? ? "embedded" : "raw")
        end
        restored.size
      end

      # ─── Read ────────────────────────────────────────────────────────────────

      # @param mode [Symbol, nil] :keyword | :hybrid | :semantic — defaults to
      #   whatever the configured level can serve, and degrades instead of
      #   failing when vectors are unavailable or the budget is spent.
      # @param include [Symbol, Array] :imagined to opt into the ontological
      #   firewall, :summary for generated summaries.
      def recall(query, k: nil, threshold: nil, types: nil, tags: nil, mode: nil,
                 include: nil, embed_query: true, agent: nil, since: nil, until: nil, context: nil)
        ctx    = context || Context.resolve
        config = ctx.config.memory
        k      ||= config.default_k
        effective = Policy.retrieval_mode(config, requested: mode)
        scope  = base_scope(ctx, types: types, tags: tags, include: include)

        results, actual_mode =
          case effective
          when :none    then [[], :none]
          when :keyword then [keyword(query, scope, k), :keyword]
          when :hybrid  then hybrid(query, scope, k, threshold, config, embed_query)
          when :semantic then semantic(query, scope, k, threshold, config, embed_query)
          end

        if since || binding.local_variable_get(:until)
          s_time = since ? Time.parse(since.to_s) : nil rescue nil
          u_time = binding.local_variable_get(:until) ? Time.parse(binding.local_variable_get(:until).to_s) : nil rescue nil

          results = results.select do |r|
            t = r.created_at || Time.now
            (s_time.nil? || t >= s_time) && (u_time.nil? || t <= u_time)
          end
        end

        results.each { |r| bump_recall(r, config) }

        Telemetry.emit("memory.recall",
                       dims: { agent: agent, mode: actual_mode, requested_mode: mode,
                               degraded: mode && actual_mode != mode },
                       measures: { k: k, hits: results.size,
                                   top_score: results.first ? 1.0 : 0.0 })
        results
      end

      # Did the retrieved memories actually influence the answer? Without this,
      # nobody can tell whether RAG is earning its embedding bill.
      def mark_used(memories, output, agent: nil)
        return if memories.nil? || memories.empty?

        text = output.to_s.downcase
        used = memories.count do |m|
          shingles(m.content).any? { |s| text.include?(s) }
        end
        Telemetry.emit("memory.recall.used",
                       dims: { agent: agent },
                       measures: { used: used, offered: memories.size,
                                   used_in_output: used.positive? })
        used
      end

      def find(id) = store_backend.find(id)
      def all(scope = {}) = store_backend.all(scope)

      # How many memories match a scope. Counted in the store rather than by
      # loading them, so a dashboard tile costs one query instead of the table.
      def count(scope = {}) = store_backend.count(scope)

      def perspectives_of(record)
        store_backend.all(derived_from: record.id)
      end

      # ─── Maintenance ─────────────────────────────────────────────────────────

      def flush_embeddings!(limit: nil) = embedder.flush!(nil, limit: limit)
      def gc!(scope: {})                = embedder.gc!(nil, scope: scope)

      # Predicts the bill of a policy before you turn it on — so the decision is
      # made with numbers instead of by trial and invoice.
      def estimate_embedding_cost(scope: {}, policy: nil, context: nil)
        config  = (context || Context.resolve).config.memory
        config  = config.with(embedding: { policy: policy }) if policy
        records = store_backend.all(scope)

        would = records.select { |r| %i[now batch].include?(Policy.decide(r, config)) }
        would = dedupe_projection(would) if config.embedding.dedupe
        tokens = would.sum { |r| (r.content.to_s.length / 4.0).ceil }
        usd    = LLM::Pricing.cost(model: config.embedding.model, input_tokens: tokens, output_tokens: 0)

        immediate = records.size
        imm_tokens = records.sum { |r| (r.content.to_s.length / 4.0).ceil }
        {
          memories: records.size, would_embed: would.size, tokens: tokens, usd: usd.round(6),
          policy: config.embedding.policy,
          vs_immediate: {
            would_embed: immediate,
            usd: LLM::Pricing.cost(model: config.embedding.model, input_tokens: imm_tokens, output_tokens: 0).round(6)
          }
        }
      end

      private

      def keyword(query, scope, k)
        store_backend.keyword_search(query, scope: scope, limit: k)
      end

      # SQL filters the candidate pool, the vector only reorders it. Cheaper on
      # both the provider and the index than a pure vector scan.
      def hybrid(query, scope, k, threshold, config, embed_query)
        candidates = store_backend.keyword_search(query, scope: scope, limit: config.hybrid_candidates)
        embedded   = candidates.select(&:embedded?)
        return [candidates.first(k), :keyword] if embedded.empty? || !embed_query

        vector = embedder.query_vector(query, config)
        return [candidates.first(k), :keyword] if vector.nil?

        ranked = store_backend.vector_search(vector, scope: scope, limit: k,
                                             threshold: threshold || config.default_threshold,
                                             candidates: embedded)
        ranked.empty? ? [candidates.first(k), :keyword] : [ranked.map(&:first), :hybrid]
      end

      def semantic(query, scope, k, threshold, config, embed_query)
        vector = embed_query ? embedder.query_vector(query, config) : nil
        return [keyword(query, scope, k), :keyword] if vector.nil?

        ranked = store_backend.vector_search(vector, scope: scope, limit: k,
                                             threshold: threshold || config.default_threshold)
        [ranked.map(&:first), :semantic]
      end

      def base_scope(ctx, types:, tags:, include:)
        ontological = ["real"] + Array(include).map(&:to_s)
        {
          tenant_key: ctx.tenant_key, account_id: id_of(ctx.account),
          types: types, tags: tags,
          status: %w[raw embedded consolidated],
          ontological: ontological.uniq
        }.compact
      end

      # Recall counts feed the `:on_promotion` policy: a memory that people keep
      # finding useful earns its vector.
      def bump_recall(record, config)
        record.touch_recall!
        store_backend.update(record.id, recall_count: record.recall_count,
                                        last_recalled_at: record.last_recalled_at)
        return if record.embedded? || config.embedding.policy != :on_promotion

        promote!(record, reason: :recall_threshold) if Policy.promoted?(record, config)
      end

      def dedupe_projection(records)
        records.uniq(&:content_hash)
      end

      def default_importance(type)
        case type.to_s
        when "insight", "summary" then 0.8
        when "pattern"            then 0.7
        else                           0.5
        end
      end

      def shingles(text, size: 6)
        words = text.to_s.downcase.scan(/[[:alnum:]]+/)
        return [] if words.size < size

        words.each_cons(size).map { |w| w.join(" ") }.first(20)
      end

      def id_of(obj) = obj.respond_to?(:id) ? obj.id : obj
    end
  end
end
