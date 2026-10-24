# frozen_string_literal: true

module GovernedStudyFixture
  def build_study(context: Agentkit::Context.new(tenant_key: "study-tenant"),
                  executor: nil, **overrides)
    h = Agentkit::Harness
    base = h::Manifest.new(id: "support", version: "1", output_contract: {}, components: [
      h::Component.new(name: "planner", type: :system_prompt, configuration: { text: "answer" })
    ])
    revision = h::Revision.new(id: "citations", base_digest: base.digest, scope: :invariant,
      rationale: "verify", changes: [
        { id: "replace", operation: :replace, rationale: "verify",
          component: h::Component.new(name: "planner", type: :system_prompt, configuration: { text: "verify" }) }
      ])
    tasks = (1..6).map do |n|
      h::ExperimentTask.new(id: "task-#{n}", input_reference: "private:#{n}",
        input_digest: h.digest("input-#{n}"), model: "fixed-model", output_contract: {})
    end
    executor ||= ->(request) {
      { output_digest: h.digest("output"),
        metrics: { quality: request["role"] == "baseline" ? 0.4 : 0.9, cost: 1, latency: 10 } }
    }
    h::GovernedStudy.new(**{
      id: "support-v2", base: base, revisions: [revision], training_tasks: tasks.first(3),
      holdout_tasks: tasks.last(3), executor: executor, executor_digest: h.digest("executor-v1"),
      context: context
    }.merge(overrides))
  end

  def study_settings
    Agentkit.config.exploration.enabled = true
    Agentkit.config.exploration.min_training_worlds = 3
    Agentkit.config.exploration.min_holdout_worlds = 3
    Agentkit.config.exploration.bootstrap_samples = 200
    Agentkit.config.exploration.max_rounds = 8
    Agentkit.config.exploration.max_nodes = 64
  end

  def study_evidence(study)
    training = study.run_training
    selection = study.select(training_worlds: training)
    [selection, study.run_holdout(selection: selection)]
  end
end
