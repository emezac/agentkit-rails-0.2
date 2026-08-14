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
        def insert_chunks(corpus_name, chunks, embeddings: []) = raise NotImplementedError
        def keyword_search(corpus_name, query, limit: 50, filter: {}) = raise NotImplementedError
        def vector_search(corpus_name, vector, limit: 5, threshold: 0.3, filter: {}) = raise NotImplementedError
        def cleanup_partial_index(corpus_name) = raise NotImplementedError
        def drop_corpus(corpus_name) = raise NotImplementedError
        def count(corpus_name = nil) = raise NotImplementedError
        def delete_all = raise NotImplementedError
      end

      # ─── In-memory Store ───────────────────────────────────────────────────

      class InMemoryStore < Base
        def initialize
          @chunks = {} # corpus_name => Array of Hash chunks
          @mutex = Mutex.new
        end

        def insert_chunks(corpus_name, chunks, embeddings: [])
          @mutex.synchronize do
            @chunks[corpus_name.to_s] ||= []
            chunks.each_with_index do |c, i|
              emb = embeddings[i]
              record = c.dup.transform_keys(&:to_s)
              record["corpus_name"] = corpus_name.to_s
              record["embedding"] = emb
              @chunks[corpus_name.to_s] << record
            end
          end
          chunks.size
        end

        def keyword_search(corpus_name, query, limit: 50, filter: {})
          pool = @chunks[corpus_name.to_s] || []
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

        def vector_search(corpus_name, vector, limit: 5, threshold: 0.3, filter: {})
          pool = @chunks[corpus_name.to_s] || []
          return [] if pool.empty? || vector.nil?

          pool.filter_map do |chunk|
            next unless matches_filter?(chunk, filter)
            emb = chunk["embedding"]
            next if emb.nil? || emb.empty?

            dist = cosine_distance(vector, emb)
            [chunk, dist] if dist < threshold
          end.sort_by { |(_, d)| d }.first(limit)
        end

        def cleanup_partial_index(corpus_name)
          @mutex.synchronize { @chunks.delete(corpus_name.to_s) }
        end
        alias drop_corpus cleanup_partial_index

        def count(corpus_name = nil)
          if corpus_name
            (@chunks[corpus_name.to_s] || []).size
          else
            @chunks.values.sum(&:size)
          end
        end

        def delete_all
          @mutex.synchronize { @chunks.clear }
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

        def insert_chunks(corpus_name, chunks, embeddings: [])
          rows = chunks.each_with_index.map do |c, i|
            emb = embeddings[i]
            {
              corpus_name:   corpus_name.to_s,
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

        def keyword_search(corpus_name, query, limit: 50, filter: {})
          terms = query.to_s.strip
          return [] if terms.empty?

          rel = model.where(corpus_name: corpus_name.to_s)
          rel = rel.where(chapter_index: filter[:chapter_index]) if filter[:chapter_index]

          rel.where("search_vector @@ plainto_tsquery('simple', ?) OR content % ?", terms, terms)
             .order(Arel.sql("ts_rank(search_vector, plainto_tsquery('simple', #{model.connection.quote(terms)})) DESC"))
             .limit(limit)
             .map(&:to_hash)
        end

        def vector_search(corpus_name, vector, limit: 5, threshold: 0.3, filter: {})
          literal = "[#{vector.join(',')}]"
          rel = model.where(corpus_name: corpus_name.to_s).where.not(embedding: nil)
          rel = rel.where(chapter_index: filter[:chapter_index]) if filter[:chapter_index]

          rows = rel.where("embedding <=> CAST(? AS vector) < ?", literal, threshold)
                    .select(Arel.sql("agentkit_knowledge_chunks.*, (embedding <=> CAST(#{model.connection.quote(literal)} AS vector)) AS distance"))
                    .order(Arel.sql("distance"))
                    .limit(limit)
          rows.map { |r| [r.to_hash, r.attributes["distance"].to_f] }
        end

        def cleanup_partial_index(corpus_name)
          model.where(corpus_name: corpus_name.to_s).delete_all
        end
        alias drop_corpus cleanup_partial_index

        def count(corpus_name = nil)
          corpus_name ? model.where(corpus_name: corpus_name.to_s).count : model.count
        end

        def delete_all
          model.delete_all
        end
      end
    end
  end
end
