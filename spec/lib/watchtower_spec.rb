# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentkit::Watchtower do
  it "preserves unresolved findings on failed observation and resolves only after recovery" do
    allow(described_class).to receive(:adapter_findings).and_return([
      described_class.send(:system_issue, "existing", "high", "__global__", { detail: "pending" })
    ])
    described_class.scan!
    allow(described_class).to receive(:adapter_findings).and_return([])
    allow(Agentkit::Telemetry).to receive(:events).and_raise("secret provider token")
    findings = described_class.scan!
    expect(findings.map(&:detector)).to include("observation_unavailable")
    expect(described_class.issues(status: :open).map(&:detector)).to include("existing")
    expect(findings.map(&:evidence).inspect).not_to include("secret provider token")
    allow(Agentkit::Telemetry).to receive(:events).and_return([])
    described_class.scan!
    expect(described_class.issues(status: :open)).to be_empty
  end

  it "deduplicates findings with a stable fingerprint" do
    Agentkit.config.actions.approved_without_job_after = 0
    Agentkit::Capability.register(:review) { |cap| cap.risk :irreversible; cap.executor { {} } }
    requester = Agentkit::Principal.new(id: "user:1")
    proposal = Agentkit::Actions.propose!(capability: :review, arguments: {}, requester: requester)
    store = Agentkit::Actions.store
    store.decide(proposal.id,
                 Agentkit::Actions::Decision.new(proposal_id: proposal.id,
                                                 tenant_key: proposal.tenant_key,
                                                 decision: "approved",
                                                 actor_principal_id: "reviewer:1",
                                                 decided_at: Time.now,
                                                 approved_arguments_digest: proposal.arguments_digest,
                                                 policy_version: proposal.policy_version),
                 create_outbox: false)

    2.times { described_class.scan!(now: Time.now + 1) }
    expect(described_class.issues(status: :open).map(&:detector))
      .to eq(["approved_without_execution"])
  end
end
