# frozen_string_literal: true

module Agentkit
  module RAG
    # End-to-end RAG pipeline: retrieval → context assembly → LLM generation (with optional streaming).
    class Pipeline
      def initialize(retriever: nil, config: nil)
        @config    = config || Agentkit.config.rag
        @retriever = retriever || Retriever.new(config: @config)
      end

      attr_reader :config, :retriever

      def generate(query, corpus_name: "default_corpus", top_k: nil, filter: {}, system_prompt: nil, &stream_block)
        retrieved = retriever.retrieve(query, corpus_name: corpus_name, top_k: top_k, filter: filter)

        context_str = retrieved.map.with_index(1) do |doc, i|
          source_info = doc['source'] ? " (Source: #{doc['source']})" : ""
          chapter_info = doc['chapter_title'] ? " [#{doc['chapter_title']}]" : ""
          "[#{i}]#{chapter_info}#{source_info}:\n#{doc['text']}"
        end.join("\n\n")

        system = system_prompt || <<~SYS
          You are a helpful knowledge assistant. Use the retrieved context below to answer the user's question accurately.
          If the context does not contain enough information, acknowledge it.
        SYS

        user_content = <<~USER
          Retrieved Context:
          #{context_str}

          User Question:
          #{query}
        USER

        response = LLM.complete(
          user_content,
          system: system,
          model: config.respond_to?(:model) ? config.model : :default,
          &stream_block
        )

        {
          "answer" => response.to_s,
          "retrieved" => retrieved,
          "context" => context_str
        }
      end
    end
  end
end
