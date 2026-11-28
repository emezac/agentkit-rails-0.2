# frozen_string_literal: true

require "spec_helper"
require_relative "../../examples/research_evidence_gates"

RSpec.describe Agentkit::Harness::ResearchEvidence do
  let(:researcher) { Agentkit::Context.new(tenant_key: "demo", principal: "researcher") }
  let(:verifier) { researcher.derive(principal: "verifier") }
  let(:service) { ResearchEvidenceGatesExample.gate }
  let(:test_case) { ResearchWorkflowExample::CASES.first }
  let(:questions) { test_case.fetch("questions") }
  let(:sources) { ResearchEvidenceGatesExample.sources_for(test_case, context: researcher) }

  it "builds and independently verifies exact evidence in all twelve cases without model calls" do
    rows = ResearchEvidenceGatesExample.run
    expect(rows.size).to eq(12)
    expect(rows).to all(include("verified" => true))
    expect(rows.find { |row| row.fetch("case_id") == "priority_conflict" }.fetch("unresolved"))
      .to eq([{ "question_id" => "delivery_promise", "reason" => "conflicting_sources",
                "source_ids" => %w[priority-a-v1 priority-b-v1] }])
    expect(rows.find { |row| row.fetch("case_id") == "gift_cards" }.fetch("unresolved"))
      .to include({ "question_id" => "balance_transfer", "reason" => "no_matching_primary_source",
                     "source_ids" => [] })
    expect(Agentkit::LLM::Adapters::Fake.call_count).to eq(0)
  end

  it "rejects a changed quote and stale source bytes" do
    report = service.build(questions: questions, sources: sources, context: researcher)
    tampered = Marshal.load(Marshal.dump(report))
    tampered.fetch("claims").first["quote"] = "Returns last 90 days."
    expect(service.verify(report: tampered, questions: questions, sources: sources,
      context: verifier)).to include("verified" => false, "issues" => ["evidence_mismatch"])

    changed_loader = ->(ref, context) do
      row = ResearchWorkflowExample::REPOSITORY.fetch(ref.fetch("id"), context: context)
      row.slice("id", "reference", "version", "kind")
        .merge("scope" => Agentkit::Knowledge::Boundary.scope(context), "content" => "A changed policy.")
    end
    changed = described_class.new(loader: changed_loader, authorize: ->(*) { true })
    expect { changed.verify(report: report, questions: questions, sources: sources, context: verifier) }
      .to raise_error(Agentkit::Knowledge::IntegrityError)
  end

  it "keeps build and verification on separate principals and tenant scopes" do
    report = service.build(questions: questions, sources: sources, context: researcher)
    expect { service.verify(report: report, questions: questions, sources: sources, context: researcher) }
      .to raise_error(Agentkit::Knowledge::AccessDenied)
    expect { service.build(questions: questions, sources: sources, context: verifier) }
      .to raise_error(Agentkit::Knowledge::AccessDenied)
    foreign = Agentkit::Context.new(tenant_key: "other", principal: "verifier")
    expect { service.verify(report: report, questions: questions, sources: sources, context: foreign) }
      .to raise_error(Agentkit::Knowledge::AccessDenied)
  end

  it "does not turn a matching secondary source into a claim" do
    source = sources.first.merge("kind" => "secondary")
    loader = ->(ref, context) do
      row = ResearchWorkflowExample::REPOSITORY.fetch(ref.fetch("id"), context: context)
      row.slice("id", "reference", "version", "content")
        .merge("kind" => "secondary", "scope" => Agentkit::Knowledge::Boundary.scope(context))
    end
    gate = described_class.new(loader: loader, authorize: ->(*) { true })
    report = gate.build(questions: [questions.first], sources: [source], context: researcher)

    expect(report.fetch("claims")).to be_empty
    expect(report.fetch("unresolved")).to eq([{ "question_id" => questions.first.fetch("id"),
      "reason" => "no_matching_primary_source", "source_ids" => [] }])
    expect(gate.verify(report: report, questions: [questions.first], sources: [source], context: verifier))
      .to include("verified" => true, "authorizes" => false)
  end

  it "rejects oversized input and duplicate identifiers before loading sources" do
    expect { service.build(questions: questions * 33, sources: sources, context: researcher) }
      .to raise_error(Agentkit::Knowledge::InvalidContract)
    expect { service.build(questions: questions, sources: sources + sources.first(1), context: researcher) }
      .to raise_error(Agentkit::Knowledge::InvalidContract)
  end
end
