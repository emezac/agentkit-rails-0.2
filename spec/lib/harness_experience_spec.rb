# frozen_string_literal: true

require "spec_helper"
require_relative "../support/harness_experience_fixture"

RSpec.describe Agentkit::Harness::ExperienceLibrary do
  include HarnessExperienceFixture
  before do
    Agentkit.config.memory.store = :memory
    Agentkit.config.memory.level = :log
  end
  let(:context) { Agentkit::Context.new(tenant_key: "acme") }
  let(:library) { described_class.new(domain: "support", context: context) }
  let(:result) { experiment_result(context: context) }

  it "retains provenance and one candidate per experiment across library instances" do
    entry = capture(library, result)
    expect(entry.status).to eq("candidate")
    expect(entry.data.fetch("provenance").fetch("result_digest")).to eq(result.digest)
    expect(capture(library, result).id).to eq(entry.id)
    restored = described_class.new(domain: "support", context: context).find(entry.id)
    expect(restored.digest).to eq(entry.digest)
    expect(entry.to_h.to_s).not_to include("secret output", "secret task")
    expect(library.retrieve(query: "citations").evidence).to be_empty
  end

  it "retrieves activated lessons as bounded, untrusted hypotheses" do
    entry = capture(library, result)
    library.transition!(entry.id, to: :active, actor: "human:1", reason: "reviewed")
    compiled = library.retrieve(query: "citations")
    expect(compiled.fragment).to include("Hypothesis: revalidate", "untrusted data", "Check citations")
    expect(compiled.evidence.size).to eq(1)
    expect(library.retrieve(query: "unrelated").evidence).to be_empty
  end

  it "excludes expired entries immediately and maintains them non-destructively" do
    at = Time.now.utc
    entry = capture(library, result, ttl: 10, at: at)
    library.transition!(entry.id, to: :active, actor: "human:1", reason: "reviewed", at: at)
    expect(library.retrieve(query: "citations", at: at + 11).evidence).to be_empty
    expect(library.maintain!(at: at + 11)[:stale_ids]).to eq([entry.id])
    expect(library.find(entry.id).status).to eq("active")
    library.maintain!(dry_run: false, at: at + 11)
    expect(library.find(entry.id).status).to eq("stale")
    expect { library.transition!(entry.id, to: :active, actor: "human:1", reason: "retry") }
      .to raise_error(Agentkit::HarnessExperimentError)
  end

  it "rejects activation after expiry and terminal state changes" do
    at = Time.now.utc
    entry = capture(library, result, ttl: 1, at: at)
    expect { library.transition!(entry.id, to: :active, actor: "human:1", reason: "review", at: at + 2) }
      .to raise_error(Agentkit::HarnessExperimentError, /expired/)
    library.transition!(entry.id, to: :rejected, actor: "human:1", reason: "insufficient")
    expect { library.transition!(entry.id, to: :active, actor: "human:1", reason: "review") }
      .to raise_error(Agentkit::HarnessExperimentError, /invalid/)
  end

  it "isolates tenant, account and domain on both capture and retrieval" do
    entry = capture(library, result)
    other = described_class.new(domain: "support", context: Agentkit::Context.new(tenant_key: "beta"))
    expect(other.find(entry.id)).to be_nil
    expect { capture(other, result) }.to raise_error(Agentkit::HarnessIntegrityError, /scope/)
    expect(described_class.new(domain: "billing", context: context).find(entry.id)).to be_nil
    account = AgentkitSpecHelpers::Account.new(42, "acme", "pro")
    scoped = described_class.new(domain: "support", context: Agentkit::Context.new(tenant_key: "acme", account: account))
    expect(scoped.find(entry.id)).to be_nil
    expect(described_class.new(domain: "support", context: Agentkit::Context.new).find(entry.id)).to be_nil
  end

  it "does not learn from confounded, unchanged, failed or single-rollout evidence" do
    %w[confounded no_observed_effect].each do |verdict|
      expect(capture(library, experiment_result(context: context, verdict: verdict))).to be_nil
    end
    expect(capture(library, experiment_result(context: context, repetitions: 1))).to be_nil
    expect(capture(library, experiment_result(context: context, failure: true))).to be_nil
    expect(library.entries).to be_empty
  end

  it "retains negative lessons even when the composer keeps the base" do
    entry = capture(library, experiment_result(context: context, verdict: "hurt"))
    expect(entry.status).to eq("candidate")
    expect(entry.data.dig("provenance", "contrast", "attributions", 0, "verdict")).to eq("hurt")
  end

  it "supersedes with a reviewed active replacement and preserves history" do
    first = capture(library, result)
    second = capture(library, experiment_result(context: context, id: "second"))
    [first, second].each { |e| library.transition!(e.id, to: :active, actor: "human:1", reason: "review") }
    library.transition!(first.id, to: :superseded, actor: "human:1", reason: "consolidate", replacement_id: second.id)
    expect(library.retrieve(query: "citations").selected_source_ids).to eq([second.id])
    expect(library.find(first.id).data["replacement_id"]).to eq(second.id)
  end

  it "fails closed for tampered snapshots" do
    capture(library, result)
    row = Agentkit::Memory.store_backend.all(types: [described_class::MEMORY_TYPE]).first
    row.metadata = row.metadata.merge("digest" => "tampered")
    expect { library.entries }.to raise_error(Agentkit::HarnessIntegrityError)
  end

  it "refuses persistence when Memory is disabled" do
    completed = result
    Agentkit.config.memory.level = :off
    expect { capture(library, completed) }.to raise_error(Agentkit::HarnessPersistenceError)
  end

  it "fails closed on conflicting concurrent review histories" do
    entry = capture(library, result)
    library.transition!(entry.id, to: :active, actor: "human:1", reason: "reviewed")
    fork = Agentkit::Harness::Experience.new(entry.to_h.merge(
      "status" => "rejected", "generation" => 2, "parent_digest" => entry.digest
    ))
    Agentkit::Memory.store("conflicting review", type: described_class::MEMORY_TYPE,
      ontological_type: :imagined, embed: false, context: context,
      metadata: { "domain" => "support", "experience" => fork.to_h, "digest" => fork.digest })
    expect { library.retrieve(query: "citations") }.to raise_error(Agentkit::HarnessIntegrityError, /conflict/)
  end
end
