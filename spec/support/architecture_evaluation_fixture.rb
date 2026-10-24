# frozen_string_literal: true
require_relative "governed_study_fixture"

module ArchitectureEvaluationFixture
  include GovernedStudyFixture

  def architecture_study(critical: true, max_regressions: 0, fail_task: nil,
                         flaky: false, failed_check: false, missing_chain: false,
                         context: Agentkit::Context.new(tenant_key: "architecture"), diagnostics: nil,
                         baseline_fail_task: nil)
    h = Agentkit::Harness
    tasks = (1..6).map do |n|
      chain = missing_chain && n >= 4 ? ["shipping", "orders"] : ["orders", "shipping"]
      h::ExperimentTask.new(id: "case-#{n}", input_reference: "private:#{n}",
        input_digest: h.digest("case-input-#{n}"), model: "fixed-model", output_contract: {},
        metadata: { architecture: { critical: critical && [1, 4].include?(n),
                                    required_checks: ["policy"], chain: chain } })
    end
    policy = h::ArchitectureEvaluation.new(max_regressions: max_regressions,
      required_chains: [["orders", "shipping"]])
    executor = ->(request) {
      n = request.fetch("task").fetch("id").delete_prefix("case-").to_i
      candidate = request["role"] == "candidate"
      fail_here = (candidate && n == fail_task && (!flaky || request["repetition"] == 2)) ||
                  (!candidate && n == baseline_fail_task)
      { output_digest: h.digest("private artifact"), output: "secret output",
        metrics: { quality: candidate ? 0.9 : 0.5, cost: candidate ? 1 : 2, latency: candidate ? 10 : 20 },
        evaluation: { success: failed_check ? true : !fail_here, checks: { policy: !(failed_check && fail_here) } } }
    }
    build_study(context: context, training_tasks: tasks.first(3), holdout_tasks: tasks.last(3),
                architecture_evaluation: policy, executor: executor, delegation_diagnostics: diagnostics)
  end

  def delegation_traces(tenant_key: "architecture", account_id: nil, parallel: false)
    (1..5).map do |n|
      { id: "request-#{n}", tenant_key: tenant_key, account_id: account_id,
        prompt: "secret prompt", calls: [
          { agent: "orders", start_ms: 0, duration_ms: 10, cost_usd: 0.01, input_tokens: 20, output_tokens: 5 },
          { agent: "shipping", start_ms: parallel ? 5 : 10, duration_ms: 10, cost_usd: 0.02, input_tokens: 30, output_tokens: 6 }
        ] }
    end
  end

  def delegation_catalog
    [{ name: "orders", role: "domain", context_group: "support" },
     { name: "shipping", role: "domain", context_group: "support" }]
  end

  def delegation_report(**options)
    Agentkit::Harness::DelegationDiagnostics.analyze(
      traces: delegation_traces, agents: delegation_catalog,
      context: Agentkit::Context.new(tenant_key: "architecture"), **options
    )
  end
end
