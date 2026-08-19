# frozen_string_literal: true

module Agentkit
  module RAG
    # Indexes a corpus or a CorpusSlice into the configured KnowledgeStore.
    class Indexer
      def initialize(corpus_name: "default_corpus", store: nil, config: nil, tenant_key: nil, account_id: nil)
        @corpus_name = corpus_name.to_s
        @config      = config || Agentkit.config.rag
        @store       = store || KnowledgeStore.build(@config.store)
        @chunker     = Chunker.new(chunk_size: @config.chunk_size, chunk_overlap: @config.chunk_overlap)
        @tenant_scope = RAG.resolve_tenant_scope(tenant_key: tenant_key, account_id: account_id)
      end

      attr_reader :corpus_name, :config, :store, :chunker, :tenant_scope

      def index_corpus(source, chunk_documents: true)
        docs = load_source(source)
        chunks = chunk_documents ? chunker.chunk_documents(docs) : docs

        texts = chunks.map { |c| c["text"] || c[:text] || "" }
        embeddings = generate_embeddings(texts)

        store.insert_chunks(corpus_name, chunks, embeddings: embeddings, **tenant_scope)
        { corpus_name: corpus_name, chunks: chunks.size, vectors: embeddings.compact.size }
      end

      def index_slice(slice)
        slice_obj = CorpusSlice.from_h(slice)
        slice_corpus = slice_obj.corpus_name || corpus_name

        chunks = chunker.chunk_documents(slice_obj.chunks)
        chunks.each do |c|
          c["chapter_index"] ||= slice_obj.chapter_index
          c["chapter_title"] ||= slice_obj.title
        end

        texts = chunks.map { |c| c["text"] || c[:text] || "" }
        embeddings = generate_embeddings(texts)

        store.insert_chunks(slice_corpus, chunks, embeddings: embeddings, **tenant_scope)
        {
          slice_id:      slice_obj.slice_id,
          corpus_name:   slice_corpus,
          chapter_index: slice_obj.chapter_index,
          title:         slice_obj.title,
          chunks:        chunks.size,
          vectors:       embeddings.compact.size
        }
      end

      private

      def load_source(source)
        if source.is_a?(Array)
          source
        elsif source.to_s.end_with?(".pdf")
          Corpus.from_pdf(source)
        elsif source.to_s.end_with?(".jsonl")
          Corpus.from_jsonl(source)
        else
          [{ "text" => source.to_s }]
        end
      end

      def generate_embeddings(texts)
        return Array.new(texts.size) { nil } if Agentkit.config.memory.level == :keyword

        texts.map do |txt|
          vec = Memory.embedder.query_vector(txt, Agentkit.config.memory)
          vec || Array.new(config.embedding_dimensions) { rand } # fallback vector for adapters without embeddings
        end
      rescue StandardError
        Array.new(texts.size) { nil }
      end
    end
  end
end
