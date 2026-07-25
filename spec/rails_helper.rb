# frozen_string_literal: true

# Integration harness: boots a real Rails app with the engine mounted and a
# real Postgres behind it.
#
# The pure-Ruby suite (spec_helper) proves the algorithms. This one proves the
# integration — the seam where five defects shipped past a green unit suite
# during the totallook pilot.
ENV["RAILS_ENV"] = "test"

require "rspec"
require_relative "dummy/config/environment"
require_relative "dummy/db/schema_setup"

begin
  ActiveRecord::Base.connection
rescue ActiveRecord::NoDatabaseError
  config = ActiveRecord::Base.connection_db_config
  ActiveRecord::Tasks::DatabaseTasks.create(config)
  ActiveRecord::Base.establish_connection(config)
end

DummySchema.load!

RSpec.configure do |config|
  config.before(:suite) { DummySchema.truncate! }

  # Each example runs inside a transaction that is rolled back, so state never
  # leaks between examples the way it did when the HITL store was a Hash.
  config.around(:each, :integration) do |example|
    ActiveRecord::Base.transaction do
      example.run
      raise ActiveRecord::Rollback
    end
  end

  # Unit examples call Flow.test_mode!, which repoints every port at the
  # in-memory adapters on the SHARED global config. With random ordering the two
  # suites interleave, so each integration example re-pins what a booted Rails
  # app would have.
  config.before(:each, :integration) do
    Agentkit.config.flow.store      = :active_record
    Agentkit.config.flow.executor   = :async
    Agentkit.config.flow.dispatcher = :active_job
    Agentkit.config.memory.store    = :active_record
    Agentkit.config.memory.level    = :hybrid
    Agentkit.config.memory.embedding.policy = :on_promotion
    Agentkit.config.audit.store     = :active_record
    Agentkit.config.telemetry.backends = [:memory]
    Agentkit.config.llm.adapter     = :fake
    Agentkit::Audit.reset!

    Agentkit::LLM.reset!
    Agentkit::LLM::Adapters::Fake.reset!
    Agentkit::Telemetry.reset!
    Agentkit::Flow.shared_store = nil
    Agentkit::Flow.dispatcher   = nil
    Agentkit::Memory.reset!
    Agentkit::HITL.ledger = Agentkit::HITL::Stores::ActiveRecordLedger.new
    Agentkit::HITL.store  = Agentkit::HITL::Stores::ActiveRecordStore.new

    # Agentkit.reset! (called by the unit suite) clears the capability registry;
    # re-running the registration is exactly what Rails' to_prepare does on a
    # code reload.
    DummyCapabilities.register_all
  end
end

module IntegrationHelpers
  def account!(name: "Acme", plan: "pro")
    Account.create!(name: name, plan: plan)
  end

  def with_account(account, &block)
    Agentkit.with_context(Agentkit::Context.new(account: account), &block)
  end

  def fake_llm = Agentkit::LLM::Adapters::Fake
end

RSpec.configure { |c| c.include IntegrationHelpers, :integration }
