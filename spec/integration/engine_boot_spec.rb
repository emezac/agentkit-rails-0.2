# frozen_string_literal: true

require "rails_helper"
require "rake"

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
  end

  it "mounts the console and A2A routes" do
    %w[/agentkit /agentkit/runs /agentkit/factory].each do |path|
      expect { Rails.application.routes.recognize_path(path) }.not_to raise_error
    end

    expect(Rails.application.routes.recognize_path("/agentkit"))
      .to include(controller: "agentkit/suggestions", action: "index")
  end

  it "swaps the in-memory ports for the ActiveRecord ones" do
    expect(Agentkit::Memory.store_backend).to be_a(Agentkit::Memory::Stores::ActiveRecordStore)
    expect(Agentkit::Flow.shared_store).to be_a(Agentkit::Flow::Store::ActiveRecordStore)
    expect(Agentkit::HITL.store).to be_a(Agentkit::HITL::Stores::ActiveRecordStore)
  end

  it "installs the ActiveJob scheduler instead of the no-op one" do
    expect(Agentkit::HITL.scheduler).to be_a(Proc)
    expect(Agentkit::AutoApplySuggestionJob).to be < ActiveJob::Base
  end

  describe "Zeitwerk loading" do
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
        "agentkit_artifacts"
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
    expect(defined?(Agentkit::A2aController)).to be_nil
  end

  it "pins that inflection on every autoloader" do
    Rails.autoloaders.each do |autoloader|
      expect(autoloader.inflector.camelize("a2a_controller", nil)).to eq("A2AController")
    end
  end
end
