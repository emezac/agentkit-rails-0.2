# frozen_string_literal: true

require "spec_helper"
require_relative "../../examples/research_workflow"
require_relative "../../examples/research_workflow_live"

RSpec.describe ResearchWorkflowExample do
  let(:context) { Agentkit::Context.new(tenant_key: "demo", principal: "researcher") }
  let(:verifier_context) { context.derive(principal: "verifier") }
  let(:verifier) { described_class::ReportVerifier.new }
  let(:case_contract) { described_class.bind_sources(described_class::CASES.first, context: context) }

  it "runs a paired single/split research comparison over training and holdout" do
    result = described_class.compare(context: context)
    evaluation = result.fetch("evaluation")
    expect(evaluation).to include("comparable" => true, "causal" => false,
      "authorizes" => false, "auto_promoted" => false)
    expect(described_class::CASES.size).to eq(12)
    expect(evaluation.dig("phases", "training", "arms", "baseline", "verified")).to eq(6)
    expect(evaluation.dig("phases", "training", "arms", "candidate", "verified")).to eq(6)
    expect(evaluation.dig("phases", "holdout", "arms", "baseline", "verified")).to eq(6)
    expect(evaluation.dig("phases", "holdout", "arms", "candidate", "verified")).to eq(6)
    expect(result.dig("reports", "refunds", "candidate", "unresolved"))
      .to eq([{ "question_id" => "missing", "reason" => "no_matching_primary_source" }])
    expect(result.dig("reports", "returns", "baseline", "claims"))
      .to eq(result.dig("reports", "returns", "candidate", "claims"))
    expect(result.dig("reports", "priority_conflict", "candidate", "unresolved"))
      .to eq([{ "question_id" => "delivery_promise", "reason" => "conflicting_sources" }])
    expect(result.dig("reports", "gift_cards", "baseline", "unresolved"))
      .to eq([{ "question_id" => "balance_transfer", "reason" => "no_matching_primary_source" }])
  end

  it "rejects invented citations, stale versions and false unresolved items" do
    report = described_class.assemble(case_contract,
      described_class::ResearchTrack.new(context: context).call(case_contract))
    expect(verifier.verify(report: report, case_contract: case_contract, context: verifier_context).fetch("verified")).to eq(true)

    fabricated = Marshal.load(Marshal.dump(report))
    fabricated.fetch("claims").first["quote"] = "An invented 90-day return policy."
    expect(verifier.verify(report: fabricated, case_contract: case_contract, context: verifier_context).fetch("issues"))
      .to include("unsupported_claim")

    changed = Marshal.load(Marshal.dump(report))
    changed.fetch("claims").first["source_version"] = "old"
    expect(verifier.verify(report: changed, case_contract: case_contract, context: verifier_context).fetch("issues"))
      .to include("unsupported_claim")

    stale = Marshal.load(Marshal.dump(report))
    stale["source_snapshot_digest"] = Agentkit::Knowledge.digest("old sources")
    expect(verifier.verify(report: stale, case_contract: case_contract, context: verifier_context).fetch("issues"))
      .to include("source_snapshot_changed")

    revised_sources = described_class::SOURCES.map(&:dup)
    revised_sources.first["content"] = "The return window changed to 14 days."
    revised_repository = described_class::SourceRepository.new(revised_sources)
    revised_verifier = described_class::ReportVerifier.new(repository: revised_repository)
    expect(revised_verifier.verify(report: report, case_contract: case_contract,
      context: verifier_context).fetch("issues")).to include("source_snapshot_changed")

    concealed = Marshal.load(Marshal.dump(report))
    concealed.fetch("claims").shift
    concealed.fetch("unresolved") << { "question_id" => "window", "reason" => "no_matching_primary_source" }
    expect(verifier.verify(report: concealed, case_contract: case_contract, context: verifier_context).fetch("issues"))
      .to include("false_unresolved")
  end

  it "denies cross-tenant source reads to researchers and verifiers" do
    other = Agentkit::Context.new(tenant_key: "other", principal: "researcher")
    expect { described_class::ResearchTrack.new(context: other).call(case_contract) }
      .to raise_error(Agentkit::Knowledge::AccessDenied)
    report = described_class.assemble(case_contract,
      described_class::ResearchTrack.new(context: context).call(case_contract))
    expect { verifier.verify(report: report, case_contract: case_contract,
      context: other.derive(principal: "verifier")) }
      .to raise_error(Agentkit::Knowledge::AccessDenied)
    expect { verifier.verify(report: report, case_contract: case_contract, context: context) }
      .to raise_error(Agentkit::Knowledge::AccessDenied)
  end

  it "leaves distinct matching source statements unresolved instead of selecting one silently" do
    sources = [
      { "id" => "a", "tenant" => "demo", "reference" => "policy/a", "version" => "1",
        "kind" => "primary", "content" => "Returns are accepted within 30 days." },
      { "id" => "b", "tenant" => "demo", "reference" => "policy/b", "version" => "1",
        "kind" => "primary", "content" => "Returns are accepted within 14 days." }
    ]
    repository = described_class::SourceRepository.new(sources)
    test_case = { "id" => "conflict", "source_ids" => %w[a b],
      "questions" => [{ "id" => "window", "needle" => "returns" }] }
    bound = described_class.bind_sources(test_case, context: context, repository: repository)
    researcher = described_class::ResearchTrack.new(context: context, repository: repository)
    claims = test_case.fetch("source_ids").flat_map do |id|
      researcher.call(test_case.merge("source_ids" => [id]))
    end
    report = described_class.assemble(bound, claims)
    expect(report.fetch("claims")).to be_empty
    expect(report.fetch("unresolved")).to eq([{ "question_id" => "window", "reason" => "conflicting_sources" }])
    independent = described_class::ReportVerifier.new(repository: repository)
    expect(independent.verify(report: report, case_contract: bound,
      context: verifier_context).fetch("verified")).to eq(true)

    concealed = report.merge("claims" => [claims.first], "unresolved" => [])
    expect(independent.verify(report: concealed, case_contract: bound,
      context: verifier_context).fetch("issues")).to include("conflicting_sources")
  end

  it "counts malformed model output as a failed research attempt with measured usage" do
    Agentkit::ModelRouter.register(:research_live, model: "fake", price_in: 1, price_out: 1)
    Agentkit::LLM::Adapters::Fake.respond_with_turns(content: "not JSON", input_tokens: 10, output_tokens: 2)
    track = { "questions" => case_contract.fetch("questions"), "source_ids" => ["returns-v2"] }
    result = LiveResearchComparison::Track.new(context: context).call(track)
    expect(result.fetch("claims")).to be_empty
    expect(result.fetch("protocol_errors")).to eq(["invalid_json"])
    expect(result).to include("input_tokens" => 10, "output_tokens" => 2)
  end
end
