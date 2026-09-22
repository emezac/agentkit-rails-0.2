# frozen_string_literal: true

require "rails_helper"
require "rake"
require "stringio"
require_relative "../../db/migrate/015_harden_agentkit_hitl_and_audit"

# Gap #1 and #5 from the totallook pilot: the engine has to boot, its rake tasks
# have to load, and code under app/capabilities has to be reachable. None of
# that can be asserted without a real Rails process.
RSpec.describe "Engine boot", :integration do
  it "boots the application with the engine mounted" do
    expect(Rails.application).to be_initialized
    expect(Agentkit::Engine.instance).to be_a(Rails::Engine)
  end

  # This is the one that made `bin/rails` refuse to start in totallook: the
  # rake file was loaded from the wrong path.
  it "loads the engine's rake tasks" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("agentkit:doctor")

    expect(Rake::Task.task_defined?("agentkit:doctor")).to be(true)
    expect(Rake::Task.task_defined?("agentkit:estimate_embeddings")).to be(true)
    expect(Rake::Task.task_defined?("agentkit:factory_report")).to be(true)
    expect(Rake::Task.task_defined?("agentkit:exploration_maintenance")).to be(true)
    expect(Rake::Task.task_defined?("agentkit:install:migrations")).to be(true)
  end

  it "runs doctor schema checks without crossing tenants" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("agentkit:doctor")
    task = Rake::Task["agentkit:doctor"]
    previous_tenant = ENV.delete("TENANT")
    previous_multi_tenant = Agentkit.config.multi_tenant
    Agentkit.config.multi_tenant = true
    previous_stdout = $stdout
    output = StringIO.new
    $stdout = output
    task.reenable

    expect { task.invoke }.not_to raise_error
    expect(output.string).to include("running schema-only checks")
    expect(output.string).to include("Adaptive exploration schema, leases, quotas and promotion governance present")
  ensure
    $stdout = previous_stdout
    ENV["TENANT"] = previous_tenant if previous_tenant
    Agentkit.config.multi_tenant = previous_multi_tenant
    task&.reenable
  end

  it "mounts the console and A2A routes" do
    %w[/agentkit /agentkit/runs /agentkit/factory /agentkit/exploration].each do |path|
      expect { Rails.application.routes.recognize_path(path) }.not_to raise_error
    end

    expect(Rails.application.routes.recognize_path("/agentkit"))
      .to include(controller: "agentkit/suggestions", action: "index")

    expect(Rails.application.routes.recognize_path("/.well-known/agent-card.json"))
      .to include(controller: "agentkit/a2a", action: "card")
    expect(Rails.application.routes.recognize_path("/agentkit/a2a/message:send", method: :post))
      .to include(controller: "agentkit/a2a", action: "send_message")
    expect(Rails.application.routes.recognize_path("/agentkit/a2a/tasks/task-1", method: :get))
      .to include(controller: "agentkit/a2a", action: "get_task", id: "task-1")
  end

  it "swaps the in-memory ports for the ActiveRecord ones" do
    expect(Agentkit::Memory.store_backend).to be_a(Agentkit::Memory::Stores::ActiveRecordStore)
    expect(Agentkit::Flow.shared_store).to be_a(Agentkit::Flow::Store::ActiveRecordStore)
    expect(Agentkit::HITL.store).to be_a(Agentkit::HITL::Stores::ActiveRecordStore)
  end

  it "installs the ActiveJob scheduler instead of the no-op one" do
    expect(Agentkit::HITL.scheduler).to be_a(Proc)
    expect(Agentkit::AutoApplySuggestionJob).to be < ActiveJob::Base
    expect(Agentkit::ExecuteSuggestionJob).to be < ActiveJob::Base
  end

  it "keeps the console closed unless an explicit guard and principal are configured" do
    status, headers, = Rails.application.call(Rack::MockRequest.env_for("/agentkit"))

    expect(status).to eq(404)
    expect(headers["cache-control"]).to include("no-store")
    expect(headers["x-frame-options"]).to eq("DENY")
  end

  it "opens the console only through the configured fail-closed policy" do
    Agentkit.config.console.enabled = true
    Agentkit.config.console.principal_resolver = -> { "operator:7" }
    Agentkit.config.console.guard = ->(principal) { principal == "operator:7" }

    status, headers, = Rails.application.call(Rack::MockRequest.env_for("/agentkit"))

    expect(status).to eq(200)
    expect(headers["content-security-policy"]).to include("frame-ancestors 'none'")
  end

  describe "Zeitwerk loading" do
    it "registers the engine model path before Rails freezes autoload paths" do
      engine_models = Agentkit::Engine.root.join("app/models").to_s

      expect(ActiveSupport::Dependencies.autoload_paths.map(&:to_s)).to include(engine_models)
      expect(Agentkit::MemoryRecord).to be < ActiveRecord::Base
    end

    # A file under app/capabilities that only calls `Capability.register` at the
    # top level is never loaded, and fails eager-load in production. The
    # capabilities must be registered through the `to_prepare` hook.
    it "registers capabilities declared in app/capabilities" do
      expect(Agentkit::Capability.available).to include(:echo, :dangerous)
    end

    it "survives eager loading the whole app" do
      expect { Rails.application.eager_load! }.not_to raise_error
    end

    it "generates the A2A card from those capabilities" do
      account = account!
      card = with_account(account) { Agentkit::A2A.card }

      expect(card[:skills].map { |s| s[:id] }).to include("echo", "dangerous")
      expect(card[:skills].find { |s| s[:id] == "dangerous" }[:requiresHumanApproval]).to be(true)
    end
  end

  describe "migrations" do
    it "creates every table the adapters read" do
      tables = ActiveRecord::Base.connection.tables
      expect(tables).to include(
        "agentkit_memories", "agentkit_runs", "agentkit_run_steps",
        "agentkit_suggestions", "agentkit_decisions", "agentkit_events",
        "agentkit_audit_logs", "agentkit_traces", "agentkit_trace_phases",
        "agentkit_artifacts", "agentkit_a2a_tasks",
        "agentkit_action_proposals", "agentkit_action_decisions",
        "agentkit_execution_attempts", "agentkit_action_outboxes",
        "agentkit_action_outcomes", "agentkit_audit_chain_heads",
        "agentkit_watchtower_issues", "agentkit_exploration_quota_usages",
        "agentkit_exploration_quota_reservations", "agentkit_exploration_reviews",
        "agentkit_exploration_policy_bindings"
      )
    end

    it "builds the keyword search column and the partial vector index" do
      columns = ActiveRecord::Base.connection.columns(:agentkit_memories).map(&:name)
      expect(columns).to include("search_vector", "content_hash", "ontological_type",
                                 "superseded_by_id", "derived_from_memory_id")

      indexes = ActiveRecord::Base.connection.indexes(:agentkit_memories).map(&:name)
      expect(indexes).to include("idx_agentkit_memories_embedding")
    end

    it "enforces the (run_id, step_key) uniqueness the engine relies on" do
      index = ActiveRecord::Base.connection.indexes(:agentkit_run_steps)
                                .find { |i| i.columns == %w[run_id step_key] }
      expect(index).not_to be_nil
      expect(index.unique).to be(true)
    end

    it "upgrades historical duplicate idempotency keys without deleting rows" do
      migration = HardenAgentkitHitlAndAudit.new
      connection = ActiveRecord::Base.connection
      Agentkit::SuggestionRecord.delete_all

      ActiveRecord::Migration.suppress_messages { migration.down }
      connection.execute <<~SQL
        INSERT INTO agentkit_suggestions
          (suggestion_type, title, priority, status, payload, metadata,
           tenant_key, idempotency_key, created_at, updated_at)
        VALUES
          ('review', 'old one', 'medium', 'pending', '{}', '{}',
           'account:legacy', 'same-key', NOW(), NOW()),
          ('review', 'old two', 'medium', 'pending', '{}', '{}',
           'account:legacy', 'same-key', NOW(), NOW())
      SQL
      ActiveRecord::Migration.suppress_messages { migration.up }
      Agentkit::SuggestionRecord.reset_column_information

      rows = Agentkit::SuggestionRecord.where(tenant_key: "account:legacy",
                                               idempotency_key: "same-key").order(:id)
      expect(rows.count).to eq(2)
      expect(rows.first.operation_namespace).to eq("hitl.suggest:review")
      expect(rows.last.operation_namespace).to match(/hitl\.suggest:review:legacy:\d+/)
    ensure
      connection ||= ActiveRecord::Base.connection
      migration ||= HardenAgentkitHitlAndAudit.new
      unless connection.column_exists?(:agentkit_suggestions, :operation_namespace)
        ActiveRecord::Migration.suppress_messages { migration.up }
      end
      Agentkit::SuggestionRecord.reset_column_information
    end


    it "adds tenant boundaries to RAG and Team Memory tables" do
      %i[
        agentkit_knowledge_chunks agentkit_teams agentkit_memory_assets
        agentkit_wiki_pages agentkit_code_symbols agentkit_asset_bindings
      ].each do |table|
        columns = ActiveRecord::Base.connection.columns(table).map(&:name)
        expect(columns).to include("tenant_key", "account_id"), "missing tenant columns on #{table}"
      end

      knowledge_index = ActiveRecord::Base.connection.indexes(:agentkit_knowledge_chunks)
                                         .find { |index| index.name == "idx_agentkit_knowledge_tenant_chunk" }
      team_index = ActiveRecord::Base.connection.indexes(:agentkit_teams)
                                    .find { |index| index.name == "idx_agentkit_teams_tenant_name" }

      expect(knowledge_index.unique).to be(true)
      expect(team_index.unique).to be(true)
    end
  end
end

# An app cannot boot in production if eager loading fails, and eager loading is
# exactly what unit specs never exercise. Both of the defects this file guards
# were invisible until a real app tried to start.
RSpec.describe "Eager loading", :integration do
  it "loads every constant the engine ships" do
    expect { Rails.application.eager_load! }.not_to raise_error
  end

  # v0.2.1 renamed this to A2aController to satisfy Zeitwerk's default
  # camelization. That worked here — the dummy declares no acronyms — and broke
  # every host app that declares `inflect.acronym "A2A"`, which is a natural
  # thing for an app built on this gem to do. The engine now pins the
  # inflection so the constant does not depend on the host's configuration.
  it "names the A2A controller the same way regardless of host inflections" do
    expect(Agentkit::A2AController.superclass).to eq(ActionController::API)
    expect(Agentkit::A2AController.action_methods).to include("rpc", "card", "register", "invoke")
    expect(Agentkit::A2aController).to equal(Agentkit::A2AController)
  end

  it "pins that inflection on every autoloader" do
    Rails.autoloaders.each do |autoloader|
      expect(autoloader.inflector.camelize("a2a_controller", nil)).to eq("A2AController")
    end
  end
end
