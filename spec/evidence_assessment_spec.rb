# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentkit::EvidenceAssessment do
  it "keeps unsupported claims as hypotheses" do
    expect(described_class.new.to_h).to eq(
      "status" => "hypothesis_only", "source_refs" => [], "outcome_refs" => []
    )
  end

  it "records references without calling them validation" do
    assessment = described_class.new(source_refs: [ " https://example.com/a ", "https://example.com/a" ])

    expect(assessment.status).to eq("sources_found")
    expect(assessment.source_refs).to eq([ "https://example.com/a" ])
    expect(assessment).to be_frozen
    expect(assessment.source_refs).to be_frozen
  end

  it "distinguishes host-recorded outcomes from source discovery" do
    assessment = described_class.new(source_refs: [ "https://example.com/a" ], outcome_refs: [ "sale:42" ])

    expect(assessment.status).to eq("outcome_recorded")
    expect(assessment.outcome_refs).to eq([ "sale:42" ])
  end

  it "rejects ambiguous or empty evidence references" do
    expect { described_class.new(source_refs: [ "" ]) }.to raise_error(ArgumentError)
    expect { described_class.new(outcome_refs: "sale:42") }.to raise_error(ArgumentError)
    expect { described_class.new(source_refs: [ { "url" => "https://example.com" } ]) }.to raise_error(ArgumentError)
  end
end
