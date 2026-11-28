# frozen_string_literal: true

# Run: ruby -Ilib examples/research_evidence_gates.rb
require "agentkit"
require "json"
require_relative "research_workflow"

module ResearchEvidenceGatesExample
  R = ResearchWorkflowExample
  K = Agentkit::Knowledge

  def self.sources_for(case_contract, context:)
    case_contract.fetch("source_ids").map do |id|
      source = R::REPOSITORY.fetch(id, context: context)
      source.slice("id", "reference", "version", "kind")
        .merge("digest" => K.digest(source.fetch("content")))
    end
  end

  def self.gate
    Agentkit::Harness::ResearchEvidence.new(
      loader: lambda do |ref, context|
        source = R::REPOSITORY.fetch(ref.fetch("id"), context: context)
        source.slice("id", "reference", "version", "kind", "content")
          .merge("scope" => K::Boundary.scope(context))
      end,
      authorize: lambda do |action, _ref, context|
        (action == "build" && context.principal == "researcher") ||
          (action == "verify" && context.principal == "verifier")
      end
    )
  end

  def self.run
    researcher = Agentkit::Context.new(tenant_key: "demo", principal: "researcher")
    verifier = researcher.derive(principal: "verifier")
    service = gate
    R::CASES.map do |case_contract|
      sources = sources_for(case_contract, context: researcher)
      questions = case_contract.fetch("questions")
      report = service.build(questions: questions, sources: sources, context: researcher)
      checked = service.verify(report: report, questions: questions, sources: sources, context: verifier)
      { "case_id" => case_contract.fetch("id"), "phase" => case_contract.fetch("phase"),
        "verified" => checked.fetch("verified"), "claims" => report.fetch("claims").size,
        "unresolved" => report.fetch("unresolved") }
    end
  end
end

puts JSON.pretty_generate(ResearchEvidenceGatesExample.run) if $PROGRAM_NAME == __FILE__
