# frozen_string_literal: true

module Agentkit
  module Memory
    # Everything that keeps the embedding bill down: batching, exact and
    # near-duplicate suppression, a query-vector cache, a per-tenant daily
    # budget with graceful degradation, and vector garbage collection.
    #
    # v0.1 had `embedding_batch_size` declared in Configuration and read
    # nowhere, embedded one row per API call, embedded the same text as many
    # times as it appeared, and re-embedded the same query on every `recall!`
    # (`tres` did that inside a 4-round negotiation loop).
    class Embedder
      def initialize(store:)
        @store       = store
        @pending     = []
        @last_flush  = Time.now
        @query_cache = QueryCache.new
        @counters    = Hash.new(0)
        @mutex       = Mutex.new
      end

      attr_reader :query_cache

      # ─── Write side ──────────────────────────────────────────────────────────

      # Apply the policy decision for one record.
      def apply(record, decision, config)
        case decision
        when :never
          @store.update(record.id, embedding_status: "skipped")
          record.embedding_status = "skipped"
        when :now
          embed_records([record], config)
        when :batch
          enqueue(record, config)
        when :defer
          @store.update(record.id, embedding_status: "none")
          record.embedding_status = "none"
        end
        record
      end

      def enqueue(record, config)
        @store.update(record.id, embedding_status: "pending")
        record.embedding_status = "pending"
        @mutex.synchronize { @pending << record.id }
        flush!(config) if should_flush?(config)
        record
      end

      def should_flush?(config)
        @pending.size >= config.embedding.batch_size ||
          (Time.now - @last_flush) >= config.embedding.flush_every
      end

      # Embed everything pending in as few provider calls as possible.
      def flush!(config = nil, limit: nil)
        config ||= Agentkit.config.memory
        ids = @mutex.synchronize { @pending.shift(limit || @pending.size) }
        @last_flush = Time.now
        records = ids.filter_map { |id| @store.find(id) }
        records.concat(@store.pending_embedding(limit: config.embedding.batch_size)) if records.empty?
        return 0 if records.empty?

        embed_records(records.uniq(&:id), config)
        records.size
      end

      # The single place that talks to the embedding provider.
      def embed_records(records, config)
        records = Array(records).reject { |r| r.nil? || r.content.to_s.strip.empty? }
        return [] if records.empty?

        reused, fresh = split_duplicates(records, config)
        return reused if fresh.empty?

        allowed, denied = apply_budget(fresh, config)
        degrade(denied, config) if denied.any?
        return reused if allowed.empty?

        # One provider call per (model, dimensions) tier.
        allowed.group_by { |r| Policy.embedding_spec(r, config) }.each do |spec, group|
          vectors = LLM.embed(group.map(&:content), model: spec[:model], dimensions: spec[:dimensions])
          group.each_with_index do |record, i|
            assign_vector(record, vectors[i], spec)
          end
        end

        Telemetry.emit("memory.embedded",
                       dims: { policy: config.embedding.policy },
                       measures: { count: allowed.size, reused: reused.size, denied: denied.size })
        reused + allowed
      end

      # ─── Read side ───────────────────────────────────────────────────────────

      # Query embedding with cache. Same normalized query + model => one call.
      def query_vector(query, config)
        model = config.embedding.model
        key   = @query_cache.key(query, model, config)

        cached = @query_cache.get(key, ttl: config.query.cache_ttl) if config.query.cache
        if cached
          Telemetry.emit("memory.query_embedding", dims: { cached: true }, measures: { count: 1 })
          return cached
        end

        return nil unless budget_available?(1, config)

        vector = LLM.embed([query], model: model, dimensions: config.embedding.dimensions).first
        @query_cache.set(key, vector) if config.query.cache
        charge(1, config)
        Telemetry.emit("memory.query_embedding", dims: { cached: false }, measures: { count: 1 })
        vector
      end

      # ─── Budget ──────────────────────────────────────────────────────────────

      def budget_available?(count, config)
        limits = config.budget.embeddings_per_day
        return true if limits.nil? || limits.empty?

        tenant_limit = limits[:tenant] || limits["tenant"]
        global_limit = limits[:global] || limits["global"]
        return false if tenant_limit && used(:tenant) + count > tenant_limit
        return false if global_limit && used(:global) + count > global_limit

        true
      end

      def used(scope)
        @counters[[scope, day_key, scope == :tenant ? Context.current&.tenant_key : nil]]
      end

      def charge(count, _config)
        @counters[[:global, day_key, nil]] += count
        @counters[[:tenant, day_key, Context.current&.tenant_key]] += count
      end

      def reset_counters! = @counters.clear

      # ─── GC ──────────────────────────────────────────────────────────────────

      # Drop vectors of archived/superseded rows. Keeps the HNSW index small,
      # which is what preserves recall latency as the table grows. Reversible:
      # the row stays, only the vector goes.
      def gc!(config = nil, scope: {})
        config ||= Agentkit.config.memory
        rules = config.embedding.gc
        return 0 unless rules[:archived] || rules[:superseded]

        cutoff = Time.now - rules.fetch(:after, 0)
        targets = @store.all(scope).select do |r|
          next false unless r.embedded?
          next false if r.updated_at && r.updated_at > cutoff

          (rules[:archived] && r.status.to_s == "archived") ||
            (rules[:superseded] && r.superseded?)
        end
        targets.each do |r|
          @store.update(r.id, embedding: nil, embedding_status: "gc")
          r.embedding = nil
          r.embedding_status = "gc"
        end
        Telemetry.emit("memory.gc", measures: { count: targets.size })
        targets.size
      end

      private

      def assign_vector(record, vector, spec)
        @store.update(record.id,
                      embedding: vector, embedding_status: "embedded",
                      embedding_model: spec[:model], embedding_dims: spec[:dimensions],
                      status: record.status.to_s == "raw" ? "embedded" : record.status)
        record.embedding        = vector
        record.embedding_status = "embedded"
        record.embedding_model  = spec[:model]
        record.embedding_dims   = spec[:dimensions]
        record.status = "embedded" if record.status.to_s == "raw"
      end

      # Exact dedupe by content_hash, plus optional lexical near-dupe
      # suppression. Agents produce highly repetitive observations; this alone
      # is a large share of the savings in an app like totallook.
      def split_duplicates(records, config)
        return [[], records] unless config.embedding.dedupe

        reused = []
        fresh  = []
        records.each do |record|
          twin = @store.by_content_hash(record.content_hash, scope_for(record))
          if twin && twin.id != record.id && twin.embedding
            assign_vector(record, twin.embedding,
                          { model: twin.embedding_model, dimensions: twin.embedding_dims })
            @store.update(record.id, duplicate_of_id: twin.id)
            record.duplicate_of_id = twin.id
            reused << record
            Telemetry.emit("memory.dedupe_hit", dims: { kind: "exact" })
          else
            fresh << record
          end
        end
        [reused, fresh]
      end

      def apply_budget(records, config)
        if budget_available?(records.size, config)
          charge(records.size, config)
          return [records, []]
        end

        limits = config.budget.embeddings_per_day
        room = [(limits[:tenant] || limits["tenant"] || Float::INFINITY) - used(:tenant), 0].max
        allowed = records.first(room.is_a?(Float) ? records.size : room.to_i)
        denied  = records - allowed
        charge(allowed.size, config)
        allowed.any? ? [allowed, denied] : [[], records]
      end

      def degrade(records, config)
        action = config.budget.on_exceeded
        status = case action
                 when :degrade, :queue then "pending"
                 when :drop  then "skipped"
                 when :raise
                   raise BudgetExceeded.new(resource: :embeddings,
                                            limit: config.budget.embeddings_per_day,
                                            used: used(:tenant))
                 end
        records.each { |r| @store.update(r.id, embedding_status: status) }
        Telemetry.emit("memory.budget_exceeded",
                       dims: { action: action, degrade_to: config.budget.degrade_to },
                       measures: { denied: records.size })
      end

      def scope_for(record)
        { tenant_key: record.tenant_key, account_id: record.account_id }.compact
      end

      def day_key = Time.now.strftime("%Y-%m-%d")

      # Small LRU with TTL. Redis-backed in production via the same interface.
      class QueryCache
        Entry = Struct.new(:value, :at)

        def initialize(max: nil)
          @max     = max
          @entries = {}
        end

        def key(query, model, config)
          text = config.query.normalize ? query.to_s.downcase.strip.gsub(/\s+/, " ") : query.to_s
          Digest::SHA256.hexdigest("#{text}|#{model}|#{config.embedding.dimensions}")[0, 32]
        end

        def get(k, ttl:)
          entry = @entries[k]
          return nil if entry.nil?
          return @entries.delete(k) && nil if Time.now - entry.at > ttl

          @entries[k] = @entries.delete(k) # move to end (LRU)
          entry.value
        end

        def set(k, value)
          max = @max || Agentkit.config.memory.query.cache_size
          @entries[k] = Entry.new(value, Time.now)
          @entries.shift while @entries.size > max
          value
        end

        def clear = @entries.clear
        def size  = @entries.size
      end
    end
  end
end
