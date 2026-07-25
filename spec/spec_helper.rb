# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "agentkit"

# NOTE: this suite never defines a fake `RubyLLM` module.
#
# v0.1's spec_helper did exactly that, with an invented signature, so the suite
# stayed green while the real gem's API had moved — and a `chat` that could not
# run shipped to five projects. Provider isolation here goes through the
# adapter port (`Agentkit::LLM::Adapters::Fake`), which is part of the gem's
# public surface and is what domain apps use too. The contract spec for the
# real ruby_llm adapter is separate and skips when the gem is absent.
RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  config.before do |example|
    # Integration examples boot Rails and use the ActiveRecord-backed stores;
    # rails_helper owns their setup.
    next if example.metadata[:integration]

    Agentkit.reset!
    Agentkit::Flow.test_mode!
    Agentkit::Factory.reset!
    Agentkit::Cognition.reset!
    Agentkit::Proposals.reset!
    Agentkit::Setup.reset!
    Agentkit::LLM::Adapters::Fake.reset!
    Agentkit::Telemetry::Backends::MemoryBackend.instance.clear
  end
end

# ─── Shared helpers ──────────────────────────────────────────────────────────

module AgentkitSpecHelpers
  def fake_llm = Agentkit::LLM::Adapters::Fake

  def emitted(name)
    Agentkit::Telemetry.flush!
    Agentkit::Telemetry::Backends::MemoryBackend.instance.events(name: name)
  end

  def embedding_calls = fake_llm.embed_count
  def llm_calls       = fake_llm.call_count

  def with_context(**attrs, &block)
    Agentkit.with_context(Agentkit::Context.new(**attrs), &block)
  end

  # Minimal stand-ins so specs never need ActiveRecord.
  Account = Struct.new(:id, :name, :plan) do
    def tenant_key = "acct:#{id}"
  end
  Company = Struct.new(:id, :name, :sector, :geo, :size)
end

RSpec.configure { |c| c.include AgentkitSpecHelpers }
