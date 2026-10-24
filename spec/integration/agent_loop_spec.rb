# frozen_string_literal: true
require "rails_helper"
require_relative "../support/governed_study_fixture"

RSpec.describe "Progressive loop integration", :integration do
  include GovernedStudyFixture

  it "persists redacted loop receipts under the caller's tenant" do
    account = account!(name: "Loop")
    context = Agentkit::Context.new(account: account, principal: "human:loop")
    Agentkit::LLM::Adapters::Fake.respond_with_turns(content: "final answer")
    result = Agentkit::Agent.new(context: context).run_loop("PRIVATE USER INPUT")
    expect(result).to be_answered
    row = Agentkit::AuditRecord.find_by!(event_type: "agent_loop.completed", tenant_key: context.tenant_key)
    expect(row.payload["transcript_digest"]).to eq(result.transcript_digest)
    expect(row.attributes.to_s).not_to include("PRIVATE USER INPUT", "final answer")
    expect(Agentkit::AuditRecord.where(tenant_key: "other", event_type: "agent_loop.completed")).to be_empty
  end

  it "evaluates actual progressive loops through the governed task-completion gate" do
    study_settings
    context = Agentkit::Context.new(account: account!(name: "Loop evaluation"), principal: "human:evaluator")
    Agentkit::LLM::Pricing.register("fixed-model", input: 1, output: 2)
    task_list = (1..6).map do |n|
      Agentkit::Harness::ExperimentTask.new(id: "loop-case-#{n}", input_reference: "case:#{n}",
        input_digest: Agentkit::Harness.digest("input-#{n}"), model: "fixed-model", output_contract: {},
        metadata: { architecture: { critical: true, required_checks: ["source_checked"], chain: ["lookup"] } })
    end
    lookup = Agentkit::ToolContract.new(name: :lookup, description: "Read verified source", callable: -> {
      { verified: true, source: "source:42" }
    })
    executor = ->(request) {
      candidate = request["role"] == "candidate"
      if candidate
        Agentkit::LLM::Adapters::Fake.respond_with_turns(
          { tool_calls: [{ id: "search", name: "search_tools", arguments: { query: "lookup" } }] },
          { tool_calls: [{ id: "lookup", name: "lookup", arguments: {} }] },
          { content: "verified answer" }
        )
      else
        Agentkit::LLM::Adapters::Fake.respond_with_turns(content: "unverified answer")
      end
      outcome = Agentkit::Agent.new(context: Agentkit::Context.current).run_loop("lookup",
        model: request.fetch("task").fetch("model").fetch("name"), tools: [lookup])
      success = outcome.answered? && outcome.content == "verified answer" && outcome.evidence_refs.any?
      { output_digest: Agentkit::Harness.digest(outcome.content),
        metrics: { quality: success ? 1.0 : 0.0, cost: outcome.usage.cost_usd, latency: outcome.usage.duration_ms },
        evaluation: { success: success, checks: { source_checked: success } } }
    }
    study = build_study(context: context, executor: executor, training_tasks: task_list.first(3),
      holdout_tasks: task_list.last(3), architecture_evaluation: Agentkit::Harness::ArchitectureEvaluation.new(
        required_chains: [["lookup"]]
      ))
    selection, holdout = study_evidence(study)
    result = study.recommend(selection: selection, holdout_worlds: holdout)
    expect(result.status).to eq("recommend_review")
    expect(result.holdout.dig("architecture_evaluation", "holdout", "fail_to_pass")).to eq(3)
    review = study.submit!(target: "harness.loop", selection: selection, holdout_worlds: holdout)
    expect(Agentkit::ExplorationReviewRecord.find_by!(dossier_id: review.id).status).to eq("pending")
  end
end
