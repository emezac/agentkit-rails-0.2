# frozen_string_literal: true

require "rails_helper"

RSpec.describe "RAG and Team Memory tenant isolation", :integration do
  it "isolates identically named RAG corpora in ActiveRecord" do
    account_a = account!(name: "RAG tenant A")
    account_b = account!(name: "RAG tenant B")

    with_account(account_a) do
      Agentkit::RAG.index(corpus_name: "shared", source: "alpha confidential handbook")
    end
    with_account(account_b) do
      Agentkit::RAG.index(corpus_name: "shared", source: "beta confidential handbook")
    end

    results_a = with_account(account_a) { Agentkit::RAG.retrieve("confidential", corpus_name: "shared") }
    results_b = with_account(account_b) { Agentkit::RAG.retrieve("confidential", corpus_name: "shared") }

    expect(results_a.map { |row| row["text"] }).to all(include("alpha"))
    expect(results_b.map { |row| row["text"] }).to all(include("beta"))
  end

  it "isolates identically named teams and assets in ActiveRecord" do
    account_a = account!(name: "Team tenant A")
    account_b = account!(name: "Team tenant B")

    team_a = with_account(account_a) { Agentkit::TeamMemory.create_team(name: "Operations") }
    team_b = with_account(account_b) { Agentkit::TeamMemory.create_team(name: "Operations") }
    with_account(account_a) do
      Agentkit::TeamMemory.create_asset(asset_type: "skill", name: "Deploy", team_id: team_a.id)
    end
    with_account(account_b) do
      Agentkit::TeamMemory.create_asset(asset_type: "skill", name: "Deploy", team_id: team_b.id)
    end

    assets_a = with_account(account_a) { Agentkit::TeamMemory.load_assets(team: "Operations") }
    assets_b = with_account(account_b) { Agentkit::TeamMemory.load_assets(team: "Operations") }

    expect(assets_a.map(&:account_id)).to contain_exactly(account_a.id)
    expect(assets_b.map(&:account_id)).to contain_exactly(account_b.id)
  end


  it "returns not found for known Memory, HITL and Flow identifiers from another tenant" do
    Agentkit.config.multi_tenant = true
    account_a = account!(name: "Kernel tenant A")
    account_b = account!(name: "Kernel tenant B")

    memory = with_account(account_a) { Agentkit::Memory.store("tenant A secret") }
    suggestion = with_account(account_a) do
      Agentkit::HITL.suggest!(type: "tenant_test", title: "A only")
    end
    run = Agentkit::Flow::Run.new(flow_name: "TenantFlow", flow_version: 1, run_id: SecureRandom.uuid,
                                  tenant_key: account_a.tenant_key, account_id: account_a.id,
                                  context: {}, input: {}, output: {})
    Agentkit::Flow.shared_store.create_run(run)

    with_account(account_b) do
      expect(Agentkit::Memory.find(memory.id)).to be_nil
      expect(Agentkit::HITL.find(suggestion.id)).to be_nil
      expect(Agentkit::Flow.shared_store.find_run(run.id)).to be_nil
      expect(Agentkit::Flow.shared_store.find_run_by_uuid(run.run_id)).to be_nil
    end
  end

  it "scopes audit, artifacts and counts before returning or aggregating" do
    Agentkit.config.multi_tenant = true
    account_a = account!(name: "Audit tenant A")
    account_b = account!(name: "Audit tenant B")
    store = Agentkit::Flow.shared_store

    artifact_id = with_account(account_a) do
      Agentkit::Audit.record(event_type: "tenant.event", payload: { marker: "alpha" })
      Agentkit::Memory.store("alpha count")
      store.put_artifact("alpha artifact")
    end
    with_account(account_b) do
      Agentkit::Audit.record(event_type: "tenant.event", payload: { marker: "beta" })
      Agentkit::Memory.store("beta count")

      expect(Agentkit::Audit.entries(event_type: "tenant.event").map { |e| e.payload["marker"] })
        .to eq(["beta"])
      expect(Agentkit::Memory.count).to eq(1)
      expect(store.get_artifact(artifact_id)).to be_nil
    end
  end

  it "fails closed without serialized scope and rejects caller-selected cross-tenant scope" do
    account_a = account!(name: "Scope tenant A")
    account_b = account!(name: "Scope tenant B")
    Agentkit.config.multi_tenant = true

    expect { Agentkit::Flow::Worker.advance(SecureRandom.uuid) }
      .to raise_error(Agentkit::ConfigurationError, /requires a tenant_key/)

    with_account(account_a) do
      expect do
        Agentkit::Memory.all(tenant_key: account_b.tenant_key)
      end.to raise_error(Agentkit::ConfigurationError, /cannot cross/)
    end
  end

  it "isolates Factory deduplication, experiments, golden sets and run records" do
    account_a = account!(name: "Factory tenant A")
    account_b = account!(name: "Factory tenant B")
    Agentkit.config.multi_tenant = true
    Agentkit::Factory::Interventions.register(
      "shared.setting", level: :n1,
      apply: ->(_experiment) {}, rollback: ->(_experiment) {}, adopt: ->(_experiment) {}
    )

    build_finding = lambda do
      Agentkit::Factory::Finding.new(
        id: SecureRandom.uuid, detector: "shared_detector", severity: :medium,
        subject: "same subject", summary: "tenant-specific evidence", evidence: {},
        suggested_level: :n1, status: "open", created_at: Time.now
      )
    end

    finding_a = with_account(account_a) { Agentkit::Factory.record_finding(build_finding.call).first }
    finding_b = with_account(account_b) { Agentkit::Factory.record_finding(build_finding.call).first }
    experiment_a = with_account(account_a) do
      Agentkit::Factory.experiment!(finding_a, target: "shared.setting", control: 1, variant: 2)
    end
    experiment_b = with_account(account_b) do
      Agentkit::Factory.experiment!(finding_b, target: "shared.setting", control: 1, variant: 3)
    end
    with_account(account_a) do
      suggestion = Agentkit::HITL.suggest!(type: "factory_case", title: "A", source_agent: "SharedAgent",
                                           payload: { "value" => "a" })
      Agentkit::HITL.approve(suggestion.id, actor: "human:a", final_payload: { "value" => "a-reviewed" })
      Agentkit::Factory.capture_golden!
    end
    with_account(account_b) do
      suggestion = Agentkit::HITL.suggest!(type: "factory_case", title: "B", source_agent: "SharedAgent",
                                           payload: { "value" => "b" })
      Agentkit::HITL.approve(suggestion.id, actor: "human:b", final_payload: { "value" => "b-reviewed" })
      Agentkit::Factory.capture_golden!
    end

    expect(finding_a.id).not_to eq(finding_b.id)
    expect(experiment_a.id).not_to eq(experiment_b.id)
    with_account(account_a) do
      expect(Agentkit::Factory.findings.map(&:id)).to contain_exactly(finding_a.id)
      expect(Agentkit::Factory.experiments.map(&:id)).to contain_exactly(experiment_a.id)
      expect(Agentkit::Factory.golden_sets["SharedAgent"].map(&:expected))
        .to contain_exactly({ "value" => "a-reviewed" })
      expect do
        Agentkit::Factory.resolve_finding!(finding_b.id, :resolved, actor: "human:a")
      end.to raise_error(Agentkit::ConfigurationError, /not found/)

      Agentkit::FactoryDiagnoseJob.perform_now(1, { tenant_key: account_a.tenant_key })
      expect(Agentkit::FactoryRunRecord.where(tenant_key: account_a.tenant_key).count).to eq(1)
      expect(Agentkit::FactoryRunRecord.where(tenant_key: account_b.tenant_key).count).to eq(0)
    end
  end
end
