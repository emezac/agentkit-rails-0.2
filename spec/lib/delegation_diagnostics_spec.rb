# frozen_string_literal: true
require "spec_helper"
require_relative "../support/architecture_evaluation_fixture"

RSpec.describe Agentkit::Harness::DelegationDiagnostics do
  include ArchitectureEvaluationFixture

  it "suggests merging frequent sequential peers sharing context and records exact chain coverage" do
    report = delegation_report
    expect(report.to_h["pairs"].first).to include("decision" => "merge_candidate", "serial_requests" => 5)
    expect(report.to_h["agents"].map { |row| row["decision"] }).to eq(["fold_candidate"] * 2)
    expect(report.required_chains).to eq([["orders", "shipping"]])
    expect(report.to_h.dig("usage", "input_tokens")).to include("reported" => 250, "complete" => true)
    expect(report.to_h.to_s).not_to include("secret prompt", "request-1")
    expect { report.to_h["pairs"].clear }.to raise_error(FrozenError)
  end

  it "preserves overlapping independent work and does not invent a sequential chain" do
    report = described_class.analyze(traces: delegation_traces(parallel: true), agents: delegation_catalog,
      context: Agentkit::Context.new(tenant_key: "architecture"))
    expect(report.to_h["pairs"].first).to include("decision" => "inspect", "overlap_requests" => 5)
    expect(report.to_h["agents"].map { |row| row["decision"] }).to eq(["keep_as_tool"] * 2)
    expect(report.required_chains).to be_empty
    expect(report.to_h["nonlinear_requests"]).to eq(5)
  end

  it "protects verification, permission boundaries and independent contexts" do
    [{ role: "verifier" }, { permission_boundary: true }, { independent_context: true }].each do |attrs|
      catalog = delegation_catalog
      catalog.last.merge!(attrs)
      report = described_class.analyze(traces: delegation_traces, agents: catalog,
        context: Agentkit::Context.new(tenant_key: "architecture"))
      expect(report.to_h["agents"].last["decision"]).to eq("keep_as_tool")
      expect(report.to_h["pairs"].first["decision"]).to eq("inspect")
    end
  end

  it "reports insufficient evidence and missing metrics without assuming zero actual cost" do
    traces = delegation_traces.first(1)
    traces.first[:calls].each { |call| call.delete(:cost_usd) }
    report = described_class.analyze(traces: traces, agents: delegation_catalog,
      context: Agentkit::Context.new(tenant_key: "architecture"))
    expect(report.to_h["agents"].map { |row| row["decision"] }).to eq(["insufficient_evidence"] * 2)
    expect(report.to_h.dig("usage", "cost_usd")).to include("complete" => false, "known_calls" => 0)
  end

  it "requires observed shared context before suggesting fold and known roles before merge" do
    catalog = delegation_catalog
    catalog.first[:context_group] = "other-context"
    options = { traces: delegation_traces, context: Agentkit::Context.new(tenant_key: "architecture") }
    report = described_class.analyze(agents: catalog, **options)
    expect(report.to_h["agents"].map { |row| row["decision"] }).to eq(["inspect"] * 2)
    catalog = delegation_catalog
    catalog.each { |agent| agent.delete(:role) }
    report = described_class.analyze(agents: catalog, **options)
    expect(report.to_h["pairs"].first["decision"]).to eq("inspect")
  end

  it "rejects foreign tenants, accounts and global-context imports" do
    [Agentkit::Context.new(tenant_key: "other"),
     Agentkit::Context.new(tenant_key: "architecture", account: 42), Agentkit::Context.new].each do |context|
      expect { described_class.analyze(traces: delegation_traces, agents: delegation_catalog, context: context) }
        .to raise_error(Agentkit::HarnessIntegrityError, /scope/)
    end
  end

  it "rejects duplicate request ids, duplicate agent names, invalid spans and excessive trace counts" do
    options = { context: Agentkit::Context.new(tenant_key: "architecture") }
    expect { described_class.analyze(traces: [delegation_traces.first] * 2, agents: delegation_catalog, **options) }
      .to raise_error(Agentkit::HarnessExperimentError, /duplicate/)
    expect { described_class.analyze(traces: delegation_traces, agents: [delegation_catalog.first] * 2, **options) }
      .to raise_error(Agentkit::HarnessExperimentError, /duplicate/)
    traces = delegation_traces
    traces.first[:calls].first[:duration_ms] = Float::INFINITY
    expect { described_class.analyze(traces: traces, agents: delegation_catalog, **options) }
      .to raise_error(Agentkit::HarnessExperimentError, /finite/)
    expect { described_class.analyze(traces: [delegation_traces.first] * 201, agents: delegation_catalog, **options) }
      .to raise_error(Agentkit::HarnessExperimentError, /bounds/)
  end
end
