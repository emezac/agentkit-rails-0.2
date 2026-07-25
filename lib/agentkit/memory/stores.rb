# frozen_string_literal: true

module Agentkit
  module Memory
    # Storage port. Two implementations: an in-process store (tests, CLI, hosts
    # without Postgres) and an ActiveRecord/pgvector store (production).
    module Stores
      def self.build(name)
        case name.to_sym
        when :memory        then InMemory.new
        when :active_record then ActiveRecordStore.new
        else raise ConfigurationError, "Unknown memory store: #{name}"
        end
      end

      class Base
        def insert(record)        = raise NotImplementedError
        def update(id, attrs)     = raise NotImplementedError
        def find(id)              = raise NotImplementedError
        def all(scope = {})       = raise NotImplementedError
        def delete_all            = raise NotImplementedError
        def by_content_hash(hash, scope = {}) = raise NotImplementedError
        def pending_embedding(limit:, scope: {}) = raise NotImplementedError
        def keyword_search(query, scope: {}, limit: 50) = raise NotImplementedError
        def vector_search(vector, scope: {}, limit: 5, threshold: 0.3, candidates: nil) = raise NotImplementedError
      end

      # ─── In-process ──────────────────────────────────────────────────────────

      class InMemory < Base
        def initialize
          @rows   = {}
          @seq    = 0
          @mutex  = Mutex.new
        end

        def insert(record)
          @mutex.synchronize do
            record.id ||= (@seq += 1)
            @rows[record.id] = record
          end
          record
        end

        def update(id, attrs)
          rec = @rows[id]
          return nil unless rec

          attrs.each { |k, v| rec.public_send(:"#{k}=", v) if rec.respond_to?(:"#{k}=") }
          rec.updated_at = Time.now unless attrs.key?(:updated_at)
          rec
        end

        def find(id) = @rows[id]

        def all(scope = {})
          @rows.values.select { |r| matches?(r, scope) }
        end

        def delete_all
          @mutex.synchronize { @rows = {}; @seq = 0 }
        end

        def by_content_hash(hash, scope = {})
          all(scope).find { |r| r.content_hash == hash && r.embedded? }
        end

        def pending_embedding(limit:, scope: {})
          all(scope).select { |r| r.embedding_status.to_s == "pending" }.first(limit)
        end

        # Token-overlap ranking. Not BM25, but enough to make `:keyword` mode a
        # real retrieval path in tests and in hosts without Postgres.
        def keyword_search(query, scope: {}, limit: 50)
          terms = tokenize(query)
          return [] if terms.empty?

          scored = all(scope).filter_map do |r|
            score = overlap_score(terms, r)
            [r, score] if score.positive?
          end
          scored.sort_by { |(_, s)| -s }.first(limit).map(&:first)
        end

        def vector_search(vector, scope: {}, limit: 5, threshold: 0.3, candidates: nil)
          pool = candidates || all(scope).select(&:embedded?)
          pool.filter_map { |r| [r, cosine_distance(vector, r.embedding)] }
              .select { |(_, d)| d < threshold }
              .sort_by { |(_, d)| d }
              .first(limit)
              .map { |(r, d)| [r, d] }
        end

        private

        def matches?(record, scope)
          scope.all? do |key, value|
            case key.to_sym
            when :tenant_key  then record.tenant_key == value
            when :account_id  then record.account_id == value
            when :user_id     then record.user_id == value
            when :types       then Array(value).map(&:to_s).include?(record.memory_type.to_s)
            when :tags        then (Array(value) - record.tags).empty?
            when :status      then Array(value).map(&:to_s).include?(record.status.to_s)
            when :ontological then Array(value).map(&:to_s).include?(record.ontological_type.to_s)
            when :source_agent then record.source_agent == value
            when :derived_from then record.derived_from_memory_id == value
            when :since       then record.created_at >= value
            else true
            end
          end
        end

        def tokenize(text)
          text.to_s.downcase.scan(/[[:alnum:]]{3,}/)
        end

        def overlap_score(terms, record)
          text  = "#{record.content} #{record.tags.join(' ')} #{record.role}".downcase
          hits  = terms.count { |t| text.include?(t) }
          return 0.0 if hits.zero?

          # Slight boost for importance so promoted memories surface first.
          (hits.to_f / terms.size) + (record.importance.to_f * 0.1)
        end

        def cosine_distance(a, b)
          return 1.0 if a.nil? || b.nil? || a.empty? || b.empty?

          dot = na = nb = 0.0
          a.each_with_index do |x, i|
            y = b[i].to_f
            dot += x * y
            na  += x * x
            nb  += y * y
          end
          return 1.0 if na.zero? || nb.zero?

          1.0 - (dot / (Math.sqrt(na) * Math.sqrt(nb)))
        end
      end

      # ─── ActiveRecord + pgvector ─────────────────────────────────────────────

      class ActiveRecordStore < Base
        def model = Agentkit::MemoryRecord

        def insert(record)
          row = model.create!(to_columns(record))
          record.id = row.id
          record
        end

        # Two traps here, both only visible against a real database:
        #   * `update_all` skips type casting entirely, so a vector never lands;
        #   * even with assignment, ActiveRecord only knows the `vector` OID if
        #     the extension existed when it built its type map. An app that
        #     migrates and reads in the same process gets a String column and
        #     "can't cast Array".
        # Encoding explicitly makes the store correct either way.
        def update(id, attrs)
          row = model.find_by(id: id)
          return nil if row.nil?

          row.update!(encode_vector(attrs))
          row
        end
        def find(id)          = wrap(model.find_by(id: id))
        def all(scope = {})   = scoped(scope).map { |r| wrap(r) }
        def delete_all        = model.delete_all

        def by_content_hash(hash, scope = {})
          wrap(scoped(scope).where(content_hash: hash, embedding_status: "embedded").first)
        end

        def pending_embedding(limit:, scope: {})
          scoped(scope).where(embedding_status: "pending").order(:created_at).limit(limit).map { |r| wrap(r) }
        end

        # tsvector + trigram. This is what makes `level: :keyword` a zero-API
        # retrieval path instead of "memory disabled".
        def keyword_search(query, scope: {}, limit: 50)
          terms = query.to_s.strip
          return [] if terms.empty?

          scoped(scope)
            .where("search_vector @@ plainto_tsquery('simple', ?) OR content % ?", terms, terms)
            .order(Arel.sql("ts_rank(search_vector, plainto_tsquery('simple', #{model.connection.quote(terms)})) DESC"))
            .limit(limit)
            .map { |r| wrap(r) }
        end

        # Bind parameters everywhere. v0.1 interpolated the vector straight into
        # the ORDER BY string, which is both an injection surface and a way to
        # miss the index.
        def vector_search(vector, scope: {}, limit: 5, threshold: 0.3, candidates: nil)
          literal = "[#{vector.join(',')}]"
          relation = candidates ? scoped(scope).where(id: candidates.map(&:id)) : scoped(scope)
          rows = relation
                 .where.not(embedding: nil)
                 .where("embedding <=> CAST(? AS vector) < ?", literal, threshold)
                 .select(Arel.sql("agentkit_memories.*, (embedding <=> CAST(#{model.connection.quote(literal)} AS vector)) AS distance"))
                 .order(Arel.sql("distance"))
                 .limit(limit)
          rows.map { |r| [wrap(r), r.attributes["distance"].to_f] }
        end

        private

        def scoped(scope)
          rel = model.all
          rel = rel.where(tenant_key: scope[:tenant_key]) if scope[:tenant_key]
          rel = rel.where(account_id: scope[:account_id]) if scope[:account_id]
          rel = rel.where(user_id: scope[:user_id])       if scope[:user_id]
          rel = rel.where(memory_type: Array(scope[:types])) if scope[:types]
          rel = rel.where(status: Array(scope[:status]))  if scope[:status]
          rel = rel.where(source_agent: scope[:source_agent]) if scope[:source_agent]
          rel = rel.where(derived_from_memory_id: scope[:derived_from]) if scope[:derived_from]
          rel = rel.where("created_at >= ?", scope[:since]) if scope[:since]
          rel = rel.where("tags @> ?", Array(scope[:tags]).to_json) if scope[:tags]
          # Ontological firewall: imagined scenarios are excluded unless asked for.
          rel = rel.where(ontological_type: Array(scope[:ontological] || "real"))
          rel
        end

        def to_columns(record)
          encode_vector(record.to_h.except(:id, :metadata).merge(metadata: record.metadata))
        end

        # pgvector's wire format is "[0.1,0.2,…]".
        def encode_vector(attrs)
          value = attrs[:embedding] || attrs["embedding"]
          return attrs unless value.is_a?(Array)

          attrs.merge(embedding: "[#{value.join(',')}]")
        end

        def decode_vector(value)
          return value unless value.is_a?(String)
          return nil if value.empty?

          value.delete_prefix("[").delete_suffix("]").split(",").map(&:to_f)
        end

        def wrap(row)
          return nil if row.nil?

          attrs = row.attributes.symbolize_keys.slice(*Record::ATTRIBUTES)
          attrs[:embedding] = decode_vector(attrs[:embedding])
          Record.new(**attrs)
        end
      end
    end
  end
end
