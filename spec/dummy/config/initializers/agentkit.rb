# frozen_string_literal: true

Agentkit.configure do |config|
  config.domain_name    = "Dummy"
  config.primary_entity = :account
  config.multi_tenant   = true

  # No network in specs. The fake adapter is part of the gem's public surface,
  # which is exactly why it is used here rather than a hand-rolled double.
  config.llm.adapter = :fake

  config.memory.level            = :hybrid
  config.memory.embedding.policy = :on_promotion
  config.memory.embedding.model  = "text-embedding-3-small"

  config.hitl.level = :advisory
  config.a2a.enabled     = true
  config.a2a.secret_key  = "dummy-a2a-key"
  config.telemetry.backends = [:memory]
end

Rails.application.config.to_prepare do
  DummyCapabilities.register_all
end
