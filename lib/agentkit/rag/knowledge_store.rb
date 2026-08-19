# frozen_string_literal: true

module Agentkit
  module RAG
    # Storage port for knowledge base chunks.
    # Supported stores: :memory (tests, CLI) and :active_record (pgvector + tsvector).
    module KnowledgeStore
      class << self
        def build(name)
          case name.to_sym
          when :memory        then @memory_store ||= InMemoryStore.new
          when :active_record then ActiveRecordStore.new
          else raise ConfigurationError, "Unknown knowledge store: #{name}"
          end
        end

        def reset_memory_store!
          @memory_store = nil
        end
      end

      class Base
        def insert_chunks(corpus_name, chunks, embeddings: [], tenant_key: nil, account_id: nil) = raise NotImplementedError
        def keyword_search(corpus_name, query, limit: 50, filter: {}, tenant_key: nil, account_id: nil) = raise NotImplementedError
        def vector_search(corpus_name, vector, limit: 5, threshold: 0.3, filter: {}, tenant_key: nil, account_id: nil) = raise NotImplementedError
        def cleanup_partial_index(corpus_name, tenant_key: nil, account_id: nil) = raise NotImplementedError
        def drop_corpus(corpus_name, tenant_key: nil, account_id: nil) = raise NotImplementedError
        def count(corpus_name = nil, tenant_key: nil, account_id: nil) = raise NotImplementedError
        def delete_all(tenant_key: nil, account_id: nil) = raise NotImplementedError
      end

      # ─── In-memory Store ───────────────────────────────────────────────────

      class InMemoryStore < Base
        def initialize
          @chunks = {} # [tenant_key, corpus_name] => Array of Hash chunks
          @mutex = Mutex.new
        end

        def insert_chunks(corpus_name, chunks, embeddings: [], tenant_key: nil, account_id: nil)
          key = storage_key(corpus_name, tenant_key)
          @mutex.synchronize do
            @chunks[key] ||= []
            chunks.each_with_index do |c, i|
              emb = embeddings[i]
              record = c.dup.transform_keys(&:to_s)
              record["corpus_name"] = corpus_name.to_s
              record["tenant_key"] = tenant_key
              record["account_id"] = account_id
              record["embedding"] = emb
              @chunks[key] << record
            end
          end
          chunks.size
        end

        def keyword_search(corpus_name, query, limit: 50, filter: {}, tenant_key: nil, account_id: nil)
          pool = @chunks[storage_key(corpus_name, tenant_key)] || []
          terms = tokenize(query)
          return [] if terms.empty? || pool.empty?

          scored = pool.filter_map do |chunk|
            next unless matches_filter?(chunk, filter)

            text = chunk["text"].to_s.downcase
            hits = terms.count { |t| text.include?(t) }
            [chunk, hits.to_f / terms.size] if hits.positive?
          end

          scored.sort_by { |(_, s)| -s }.first(limit).map(&:first)
        end

        def vector_search(corpus_name, vector, limit: 5, threshold: 0.3, filter: {}, tenant_key: nil, account_id: nil)
          pool = @chunks[storage_key(corpus_name, tenant_key)] || []
          return [] if pool.empty? || vector.nil?

          pool.filter_map do |chunk|
            next unless matches_filter?(chunk, filter)
            emb = chunk["embedding"]
            next if emb.nil? || emb.empty?

            dist = cosine_distance(vector, emb)
            [chunk, dist] if dist < threshold
          end.sort_by { |(_, d)| d }.first(limit)
        end

        def cleanup_partial_index(corpus_name, tenant_key: nil, account_id: nil)
          @mutex.synchronize { @chunks.delete(storage_key(corpus_name, tenant_key)) }
        end
        alias drop_corpus cleanup_partial_index

        def count(corpus_name = nil, tenant_key: nil, account_id: nil)
          if corpus_name
            (@chunks[storage_key(corpus_name, tenant_key)] || []).size
          elsif tenant_key
            @chunks.sum { |(key, _corpus), rows| key == tenant_key.to_s ? rows.size : 0 }
          else
            @chunks.values.sum(&:size)
          end
        end

        def delete_all(tenant_key: nil, account_id: nil)
          @mutex.synchronize do
            tenant_key ? @chunks.delete_if { |(key, _corpus), _rows| key == tenant_key.to_s } : @chunks.clear
          end
        end

        private

        def matches_filter?(chunk, filter)
          return true if filter.nil? || filter.empty?

          filter.all? do |k, v|
            val = chunk[k.to_s]
            val = chunk[k.to_sym] if val.nil?
            val == v || val.to_s == v.to_s
          end
        end

        def storage_key(corpus_name, tenant_key)
          [tenant_key.to_s, corpus_name.to_s]
        end

        private

        def tokenize(text)
          text.to_s.downcase.scan(/[a-z0-9]{3,}/)
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

      # ─── ActiveRecord Store ────────────────────────────────────────────────

      class ActiveRecordStore < Base
        def model
          Agentkit::KnowledgeChunkRecord
        end

        def insert_chunks(corpus_name, chunks, embeddings: [], tenant_key: nil, account_id: nil)
          validate_embedding_dimensions!(embeddings)
          rows = chunks.each_with_index.map do |c, i|
            emb = embeddings[i]
            {
              corpus_name:   corpus_name.to_s,
              tenant_key:    tenant_key,
              account_id:    account_id,
              chunk_id:      c["id"] || c[:id] || SecureRandom.uuid,
              chapter_index: c["chapter_index"] || c[:chapter_index],
              chapter_title: c["chapter_title"] || c[:chapter_title],
              content:       c["text"] || c[:text] || c["content"] || "",
              source:        c["source"] || c[:source],
              chunk_index:   c["chunk_index"] || c[:chunk_index] || 0,
              metadata:      c["metadata"] || c[:metadata] || {},
              embedding:     emb ? "[#{emb.join(',')}]" : nil,
              created_at:    Time.now,
              updated_at:    Time.now
            }
          end

          model.insert_all(rows) if rows.any?
          rows.size
        end

        def keyword_search(corpus_name, query, limit: 50, filter: {}, tenant_key: nil, account_id: nil)
          terms = query.to_s.strip
          return [] if terms.empty?

          rel = tenant_relation(tenant_key, account_id).where(corpus_name: corpus_name.to_s)
          rel = rel.where(chapter_index: filter[:chapter_index]) if filter[:chapter_index]

          rel.where("search_vector @@ plainto_tsquery('simple', ?) OR content % ?", terms, terms)
             .order(Arel.sql("ts_rank(search_vector, plainto_tsquery('simple', #{model.connection.quote(terms)})) DESC"))
             .limit(limit)
             .map(&:to_hash)
        end

        def vector_search(corpus_name, vector, limit: 5, threshold: 0.3, filter: {}, tenant_key: nil, account_id: nil)
          literal = "[#{vector.join(',')}]"
          rel = tenant_relation(tenant_key, account_id).where(corpus_name: corpus_name.to_s).where.not(embedding: nil)
          rel = rel.where(chapter_index: filter[:chapter_index]) if filter[:chapter_index]

          rows = rel.where("embedding <=> CAST(? AS vector) < ?", literal, threshold)
                    .select(Arel.sql("agentkit_knowledge_chunks.*, (embedding <=> CAST(#{model.connection.quote(literal)} AS vector)) AS distance"))
                    .order(Arel.sql("distance"))
                    .limit(limit)
          rows.map { |r| [r.to_hash, r.attributes["distance"].to_f] }
        end

        def cleanup_partial_index(corpus_name, tenant_key: nil, account_id: nil)
          tenant_relation(tenant_key, account_id).where(corpus_name: corpus_name.to_s).delete_all
        end
        alias drop_corpus cleanup_partial_index

        def count(corpus_name = nil, tenant_key: nil, account_id: nil)
          relation = tenant_relation(tenant_key, account_id)
          corpus_name ? relation.where(corpus_name: corpus_name.to_s).count : relation.count
        end

        def delete_all(tenant_key: nil, account_id: nil)
          tenant_key || account_id ? tenant_relation(tenant_key, account_id).delete_all : model.delete_all
        end

        private

        def validate_embedding_dimensions!(embeddings)
          expected = Agentkit.config.rag.embedding_dimensions.to_i
          invalid = embeddings.compact.find { |embedding| embedding.length != expected }
          return unless invalid

          raise ConfigurationError,
                "RAG embedding has #{invalid.length} dimensions; configured schema expects #{expected}"
        end

        def tenant_relation(tenant_key, account_id)
          relation = model.all
          relation = relation.where(tenant_key: tenant_key) if tenant_key
          relation = relation.where(account_id: account_id) if account_id
          relation
        end
      end
    end
  end
end
