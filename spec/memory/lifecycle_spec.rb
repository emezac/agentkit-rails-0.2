# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Memory lifecycle" do
  it "excludes expired rows from every retrieval mode but keeps them inspectable" do
    Agentkit.config.memory.embedding.policy = :immediate
    expired = Agentkit::Memory.store("Acme invoices are overdue", ttl: 0)
    live = Agentkit::Memory.store("Acme invoices are current")

    %i[keyword hybrid semantic].each do |mode|
      hits = Agentkit::Memory.recall("Acme invoices", mode: mode)
      expect(hits.map(&:id)).to include(live.id)
      expect(hits.map(&:id)).not_to include(expired.id)
    end

    expect(Agentkit::Memory.find(expired.id)).to eq(expired)
  end

  it "resolves named and per-type retention policies without changing the keep default" do
    Agentkit.config.memory.retention.policies = {
      keep: nil, brief: 60, durable: nil
    }
    Agentkit.config.memory.retention.by_type = { observation: :brief }

    before = Time.now
    brief = Agentkit::Memory.store("short-lived observation")
    durable = Agentkit::Memory.store("important conclusion", type: "insight", retention: :durable)

    expect(brief.retention_policy).to eq("brief")
    expect(brief.expires_at).to be_between(before + 59, Time.now + 61)
    expect(durable.retention_policy).to eq("durable")
    expect(durable.expires_at).to be_nil
  end

  it "rejects ambiguous or unknown retention instructions" do
    expect {
      Agentkit::Memory.store("ambiguous", ttl: 60, retention: :ephemeral)
    }.to raise_error(Agentkit::ConfigurationError, /mutually exclusive/)

    expect {
      Agentkit::Memory.store("unknown", retention: :missing)
    }.to raise_error(Agentkit::ConfigurationError, /Unknown memory retention policy/)
  end

  it "previews maintenance, archives only expired unpinned rows, and audits apply" do
    expired = Agentkit::Memory.store("expired fact", ttl: 0)
    pinned = Agentkit::Memory.store(
      "protected fact", ttl: 0, pinned: true, pin_reason: "active investigation"
    )

    preview = Agentkit::Memory.maintain!(dry_run: true, at: Time.now + 1)
    expect(preview).to be_dry_run
    expect(preview.to_h).to include(expired: 2, pinned: 1, would_archive: 1, archived: 0)
    expect(expired.status).to eq("raw")

    applied = Agentkit::Memory.maintain!(dry_run: false, at: Time.now + 1)
    expect(applied.archived).to eq(1)
    expect(expired.status).to eq("archived")
    expect(expired.archived_at).not_to be_nil
    expect(pinned.status).to eq("raw")

    events = Agentkit::Audit.entries(event_type: "memory.maintenance.applied")
    expect(events.last.payload).to include("archived" => 1, "pinned" => 1)
  end

  it "pins and unpins with scoped audit events and requires a reason" do
    record = Agentkit::Memory.store("retain this", ttl: 0)

    expect { Agentkit::Memory.store("invalid pin", pinned: true) }
      .to raise_error(ArgumentError, /pin_reason is required/)
    expect { Agentkit::Memory.pin!(record, reason: "") }
      .to raise_error(ArgumentError, /reason is required/)

    Agentkit::Memory.pin!(record.id, reason: "active investigation")
    expect(record).to be_pinned
    expect(Agentkit::Memory.recall("retain this", mode: :keyword).map(&:id)).to include(record.id)

    Agentkit::Memory.unpin!(record, reason: "investigation closed")
    expect(record).not_to be_pinned
    expect(Agentkit::Memory.recall("retain this", mode: :keyword)).to be_empty

    events = Agentkit::Audit.entries.map(&:event_type)
    expect(events).to include("memory.pinned", "memory.unpinned")
  end

  it "never archives another tenant while maintaining an explicit scope" do
    Agentkit.config.multi_tenant = true
    alpha = AgentkitSpecHelpers::Account.new(1, "Alpha", "pro")
    beta = AgentkitSpecHelpers::Account.new(2, "Beta", "pro")
    alpha_memory = with_context(account: alpha) { Agentkit::Memory.store("alpha expired", ttl: 0) }
    beta_memory = with_context(account: beta) { Agentkit::Memory.store("beta expired", ttl: 0) }

    with_context(account: alpha) do
      report = Agentkit::Memory.maintain!(dry_run: false, at: Time.now + 1)
      expect(report.archived).to eq(1)
    end

    expect(alpha_memory.status).to eq("archived")
    expect(beta_memory.status).to eq("raw")
  end
end
