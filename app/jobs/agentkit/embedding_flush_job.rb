# frozen_string_literal: true

module Agentkit
  # Drains the pending-embedding queue in batches. This is what makes
  # `embedding.policy = :batched` and `:on_promotion` real — v0.1 declared
  # `embedding_batch_size` and never read it anywhere.
  class EmbeddingFlushJob < ApplicationJob
    queue_as :agentkit_embeddings

    def perform(limit = nil, scope = nil)
      resolved = Agentkit::Scope.resolve(scope)
      count = Agentkit.with_context(Agentkit::Context.new(tenant_key: resolved.tenant_key)) do
        Agentkit::Memory.flush_embeddings!(limit: limit, scope: resolved)
      end
      Rails.logger.info("[AgentKit] flushed #{count} pending embeddings")
      count
    end
  end
end
