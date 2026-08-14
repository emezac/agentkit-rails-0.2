# frozen_string_literal: true

module Agentkit
  module RAG
    # Okapi BM25 sparse keyword search index.
    class BM25Index
      def initialize(k1: 1.5, b: 0.75)
        @k1 = k1
        @b = b
        @docs = []
        @doc_lengths = []
        @avg_dl = 0.0
        @df = Hash.new(0)
        @inverted_index = Hash.new { |h, k| h[k] = Hash.new(0) }
      end

      attr_reader :df, :doc_lengths, :avg_dl, :docs

      def build(documents)
        @docs = documents
        @doc_lengths = documents.map { |d| tokenize(d_text(d)).size }
        @avg_dl = @doc_lengths.empty? ? 0.0 : @doc_lengths.sum.to_f / @doc_lengths.size

        documents.each_with_index do |doc, doc_id|
          tokens = tokenize(d_text(doc))
          counts = Hash.new(0)
          tokens.each { |t| counts[t] += 1 }

          counts.each do |term, freq|
            @df[term] += 1
            @inverted_index[term][doc_id] = freq
          end
        end
        self
      end

      def search(query, top_k = 10)
        return [] if @docs.empty?

        q_tokens = tokenize(query)
        num_docs = @docs.size
        scores = Hash.new(0.0)

        q_tokens.each do |term|
          df = @df[term]
          next if df.zero?

          idf = Math.log((num_docs - df + 0.5) / (df + 0.5) + 1.0)
          postings = @inverted_index[term]

          postings.each do |doc_id, freq|
            doc_len = @doc_lengths[doc_id]
            tf_num = freq * (@k1 + 1.0)
            tf_den = freq + @k1 * (1.0 - @b + @b * (doc_len / [@avg_dl, 1e-5].max))
            scores[doc_id] += idf * (tf_num / tf_den)
          end
        end

        scores.sort_by { |_id, score| -score }.first(top_k)
      end

      private

      def d_text(doc)
        doc.is_a?(Hash) ? (doc["text"] || doc[:text] || doc["content"] || doc[:content]).to_s : doc.to_s
      end

      def tokenize(text)
        text.to_s.downcase.scan(/[a-z0-9]+/)
      end
    end
  end
end
