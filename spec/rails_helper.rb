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
    if example.metadata[:real_concurrency]
      DummySchema.truncate!
      begin
        example.run
      ensure
        DummySchema.truncate!
      end
    else
      ActiveRecord::Base.transaction do
        example.run
        raise ActiveRecord::Rollback
      end
    end
  end

  # Unit examples call Flow.test_mode!, which repoints every port at the
  # in-memory adapters on the SHARED global config. With random ordering the two
  # suites interleave, so each integration example re-pins what a booted Rails
  # app would have.
  config.before(:each, :integration) do
    Agentkit.config.multi_tenant      = false
    Agentkit.config.flow.store      = :active_record
    Agentkit.config.flow.executor   = :async
    Agentkit.config.flow.dispatcher = :active_job
    Agentkit.config.memory.store    = :active_record
    Agentkit.config.memory.level    = :hybrid
    Agentkit.config.memory.embedding.policy = :on_promotion
    Agentkit.config.audit.store     = :active_record
    Agentkit.config.audit.failure_mode = :best_effort
    Agentkit.config.audit.signing_keys = { "test" => "test-audit-signing-key" }
    Agentkit.config.audit.active_key_id = "test"
    Agentkit.config.audit.prompt_preview_chars = 0
    Agentkit.config.console.enabled = false
    Agentkit.config.console.guard = nil
    Agentkit.config.console.principal_resolver = nil
    Agentkit.config.console.payload_guard = nil
    Agentkit.config.a2a.expose      = nil
    Agentkit.config.a2a.hide        = []
    Agentkit.config.telemetry.backends = [:memory]
    Agentkit.config.llm.adapter     = :fake
    Agentkit::Audit.reset!
    Agentkit.config.actions.store = :active_record
    Agentkit::Actions.store = Agentkit::Actions::Stores::ActiveRecord.new
    Agentkit::Actions.dispatcher = lambda do |proposal_id, scope|
      Agentkit::Actions.execute!(proposal_id, scope: scope)
    end
    Agentkit.config.watchtower.store = :active_record
    Agentkit::Watchtower.store = Agentkit::Watchtower::ActiveRecordStore.new

    Agentkit::LLM.reset!
    Agentkit::LLM::Adapters::Fake.reset!
    Agentkit::Telemetry.reset!
    Agentkit::Flow.shared_store = nil
    Agentkit::Flow.dispatcher   = nil
    Agentkit::Memory.reset!
    Agentkit::Factory.persistence = :active_record
    Agentkit::Factory.reset!
    Agentkit::HITL.ledger = Agentkit::HITL::Stores::ActiveRecordLedger.new
    Agentkit::HITL.store  = Agentkit::HITL::Stores::ActiveRecordStore.new
    Agentkit::HITL.executor = lambda do |suggestion_id, scope|
      Agentkit::HITL.execute!(suggestion_id, scope: scope)
    end

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
