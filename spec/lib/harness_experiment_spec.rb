# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Harness experiments" do
  let(:output_contract) do
    {
      type: "object", properties: { answer: { type: "string" } },
      required: ["answer"], additionalProperties: false
    }
  end

  let(:prompt_component) do
    Agentkit::Harness::Component.new(
      name: :planner, type: :system_prompt, version: "1",
      configuration: { text: "Plan, execute, verify." }
    )
  end

  let(:base_manifest) do
    Agentkit::Harness::Manifest.new(
      id: "support-harness", version: "1", components: [prompt_component],
      output_contract: output_contract
    )
  end

  let(:task) do
    Agentkit::Harness::ExperimentTask.new(
      id: "ticket-42", input_reference: "ticket:42",
      input_digest: Agentkit::Harness.digest("customer cannot sign in"),
      model: { name: "frozen-model", temperature: 0, seed: 42 },
      output_contract: output_contract
    )
  end

  def replacement(base, id: "invariant-planning", text: "Verify before answering", scope: :invariant)
    component = Agentkit::Harness::Component.new(
      name: :planner, type: :system_prompt, version: "2",
      configuration: { text: text }
    )
    Agentkit::Harness::Revision.new(
      id: id, base_digest: base.digest, scope: scope,
      rationale: "observed an unsupported answer",
      changes: [{ id: "planner-edit", operation: :replace,
                  target: "system_prompt:planner", component: component,
                  rationale: "require evidence before completion" }]
    )
  end

  def callbacks_for(revisions, composition: nil, executor_calls: nil)
    proposer = ->(request) { expect(request).to be_frozen; revisions }
    executor = lambda do |request|
      executor_calls << request if executor_calls
      expect(request).to be_frozen
      candidate = request["role"] == "candidate"
      {
        output_reference: "artifact:#{request.fetch('probe_id')}",
        output: { answer: candidate ? "verified answer" : "guess" },
        observations: [{ kind: "verification", present: candidate }],
        metrics: { quality: candidate ? 0.9 : 0.4, tool_errors: 0 },
        evidence_refs: ["judge:#{request.fetch('probe_id')}"]
      }
    end
    contrastor = lambda do |request|
      revision = request.fetch("revision")
      baseline_ref = request.fetch("baseline_probes").first.fetch("evidence_refs").first
      candidate_ref = request.fetch("candidate_probes").first.fetch("evidence_refs").first
      {
        id: "contrast-#{revision.fetch('id')}", summary: "candidate added verification",
        attributions: revision.fetch("changes").map do |change|
          {
            change_id: change.fetch("id"), verdict: "helped",
            observation: "quality increased under a matched probe",
            evidence_refs: [baseline_ref, candidate_ref], confidence: 0.8
          }
        end
      }
    end
    composer = composition || lambda do |request|
      chosen = request.fetch("candidates").last
      contrast = request.fetch("contrasts").find do |item|
        item.fetch("revision_id") == chosen.fetch("id")
      end
      {
        action: "adopt", revision_id: chosen.fetch("id"),
        reasons: [{ summary: "matched probes improved the behavior",
                    evidence_refs: ["contrast:#{contrast.fetch('id')}"] }]
      }
    end
    [proposer, executor, contrastor, composer]
  end

  it "builds immutable, round-trippable manifests and applies typed revisions" do
    revision = replacement(base_manifest)
    candidate = revision.apply_to(base_manifest)

    expect { prompt_component.configuration["text"] << " mutate" }.to raise_error(FrozenError)
    expect(candidate.parent_digest).to eq(base_manifest.digest)
    expect(candidate.output_contract).to eq(base_manifest.output_contract)
    expect(candidate.component("system_prompt:planner").version).to eq("2")
    expect(Agentkit::Harness::Manifest.from_h(candidate.to_h).digest).to eq(candidate.digest)
    expect(Agentkit::Harness::Revision.from_h(revision.to_h).digest).to eq(revision.digest)
  end

  it "accepts only declarative JSON data in candidate components" do
    expect do
      Agentkit::Harness::Component.new(
        name: :executable, type: :middleware,
        configuration: { callable: -> { system("echo unsafe") } }
      )
    end.to raise_error(Agentkit::HarnessCandidateInvalid, /only JSON data.*Proc/)
  end

  it "requires an explicit validator opt-in before removing a component" do
    revision = Agentkit::Harness::Revision.new(
      id: "remove-planner", base_digest: base_manifest.digest, scope: :invariant,
      rationale: "simplify the harness",
      changes: [{ id: "remove", operation: :remove, target: "system_prompt:planner",
                  rationale: "test a smaller context" }]
    )

    default_report = Agentkit::Harness::CandidateValidator.new.validate(
      base: base_manifest, revision: revision
    )
    opted_in_report = Agentkit::Harness::CandidateValidator.new(allow_removals: true).validate(
      base: base_manifest, revision: revision
    )

    expect(default_report.errors.map(&:code)).to include("removal_requires_opt_in")
    expect(opted_in_report).to be_valid
  end

  it "fails closed on privilege, permission, trigger and protected-resource expansion" do
    dangerous = Agentkit::Harness::Component.new(
      name: :publisher, type: :skill, version: "1",
      configuration: { instructions: "publish" }, activation: {},
      resources: ["production/database"], permissions: ["network"],
      risk: :privileged, effect: :external
    )
    revision = Agentkit::Harness::Revision.new(
      id: "dangerous", base_digest: base_manifest.digest, scope: :domain,
      rationale: "publish directly",
      changes: [{ id: "publish", operation: :add, component: dangerous,
                  rationale: "skip the normal release path" }]
    )
    goal = Agentkit::Harness.define(
      objective: "improve support", criteria: ["answers are verified"],
      scope: { include: ["support/**"] },
      protected_resources: ["production/*"]
    )

    report = Agentkit::Harness::CandidateValidator.new.validate(
      base: base_manifest, revision: revision, goal: goal
    )

    expect(report).not_to be_valid
    expect(report.errors.map(&:code)).to include(
      "effect_expansion", "risk_expansion", "permission_expansion",
      "missing_trigger", "protected_resource", "out_of_scope_resource"
    )
  end

  it "rejects unresolved dependencies and candidates that exceed the context delta" do
    Agentkit.config.harness.max_context_delta_bytes = 10
    skill = Agentkit::Harness::Component.new(
      name: :triage, type: :skill, configuration: { instructions: "x" * 40 },
      activation: { trigger: "support ticket" }, dependencies: ["capability:lookup"]
    )
    revision = Agentkit::Harness::Revision.new(
      id: "missing-dependency", base_digest: base_manifest.digest, scope: :domain,
      rationale: "add triage",
      changes: [{ id: "triage", operation: :add, component: skill, rationale: "route tickets" }]
    )

    report = Agentkit::Harness::CandidateValidator.new.validate(base: base_manifest, revision: revision)

    expect(report.errors.map(&:code)).to include("missing_dependency", "context_budget")
  end

  it "runs matched repeated probes and adopts only an evidenced valid candidate" do
    first = replacement(base_manifest)
    skill = Agentkit::Harness::Component.new(
      name: :login_triage, type: :skill, version: "1",
      configuration: { workflow: ["inspect", "verify"] },
      activation: { trigger: "login issue" }
    )
    second = Agentkit::Harness::Revision.new(
      id: "domain-login", base_digest: base_manifest.digest, scope: :domain,
      rationale: "use the login runbook",
      changes: [{ id: "login-skill", operation: :add, component: skill,
                  rationale: "add a triggered workflow" }]
    )
    executor_calls = []
    callbacks = callbacks_for([first, second], executor_calls: executor_calls)

    result = Agentkit::Harness::Experiment.new(
      id: "exp-42", base: base_manifest, task: task, repetitions: 2,
      proposer: callbacks[0], executor: callbacks[1], contrastor: callbacks[2],
      composer: callbacks[3]
    ).run

    expect(result.kept_base?).to be(false)
    expect(result.selected_revision.id).to eq("domain-login")
    expect(result.selected_manifest.component("skill:login_triage")).not_to be_nil
    expect(result.probes.size).to eq(6)
    expect(result.contrasts.size).to eq(2)
    expect(result.probes.map(&:task_digest).uniq).to contain_exactly(task.digest)
    expect(result.probes.map(&:model_digest).uniq).to contain_exactly(task.model_digest)
    expect(result.probes.map(&:environment_digest).uniq).to contain_exactly(task.environment_digest)
    expect(result.to_h.to_s).not_to include("verified answer", "guess")
    expect(executor_calls).to all(be_frozen)
    expect(Agentkit::Audit.entries.map(&:event_type)).to include("harness.experiment.completed")
  end

  it "supports an evidenced KEEP_BASE decision" do
    revision = replacement(base_manifest)
    keep_base = lambda do |request|
      contrast = request.fetch("contrasts").first
      {
        action: "KEEP_BASE",
        reasons: [{ summary: "the observed change is not worth adopting",
                    evidence_refs: ["contrast:#{contrast.fetch('id')}"] }]
      }
    end
    callbacks = callbacks_for([revision], composition: keep_base)

    result = Agentkit::Harness::Experiment.new(
      base: base_manifest, task: task, proposer: callbacks[0], executor: callbacks[1],
      contrastor: callbacks[2], composer: callbacks[3]
    ).run

    expect(result).to be_kept_base
    expect(result.selected_manifest).to equal(base_manifest)
  end

  it "validates an evidenced composition before returning its merged manifest" do
    invariant = replacement(base_manifest)
    skill = Agentkit::Harness::Component.new(
      name: :login_triage, type: :skill,
      configuration: { workflow: ["inspect", "verify"] },
      activation: { trigger: "login issue" }
    )
    domain = Agentkit::Harness::Revision.new(
      id: "domain-login", base_digest: base_manifest.digest, scope: :domain,
      rationale: "add domain workflow",
      changes: [{ id: "login-skill", operation: :add, component: skill,
                  rationale: "use a triggered runbook" }]
    )
    composed = Agentkit::Harness::Revision.new(
      id: "composed", base_digest: base_manifest.digest, scope: :domain,
      rationale: "combine independently supported changes",
      changes: invariant.changes + domain.changes
    )
    composer = lambda do |request|
      refs = request.fetch("contrasts").map { |item| "contrast:#{item.fetch('id')}" }
      {
        action: "compose", revision: composed,
        reasons: [{ summary: "both changes have matched evidence", evidence_refs: refs }]
      }
    end
    callbacks = callbacks_for([invariant, domain], composition: composer)

    result = Agentkit::Harness::Experiment.new(
      base: base_manifest, task: task, proposer: callbacks[0], executor: callbacks[1],
      contrastor: callbacks[2], composer: callbacks[3]
    ).run

    expect(result.composition.action).to eq("compose")
    expect(result.selected_manifest.component("system_prompt:planner").version).to eq("2")
    expect(result.selected_manifest.component("skill:login_triage")).not_to be_nil
  end

  it "does not probe invalid candidates and records an automatic KEEP_BASE" do
    unsafe = Agentkit::Harness::Component.new(
      name: :planner, type: :system_prompt, configuration: { text: "write production" },
      effect: :external
    )
    revision = Agentkit::Harness::Revision.new(
      id: "unsafe", base_digest: base_manifest.digest, scope: :invariant,
      rationale: "widen authority",
      changes: [{ id: "unsafe-edit", operation: :replace,
                  target: "system_prompt:planner", component: unsafe,
                  rationale: "perform writes" }]
    )
    executions = 0
    callbacks = callbacks_for([revision])
    executor = ->(_request) { executions += 1 }

    result = Agentkit::Harness::Experiment.new(
      base: base_manifest, task: task, proposer: callbacks[0], executor: executor,
      contrastor: callbacks[2], composer: callbacks[3]
    ).run

    expect(result).to be_kept_base
    expect(result.probes).to be_empty
    expect(executions).to eq(0)
    expect(result.validations.first.errors.map(&:code)).to include("effect_expansion")
  end

  it "requires sandboxed, network-disabled and isolated probe environments" do
    unsafe_task = Agentkit::Harness::ExperimentTask.new(
      id: "unsafe", input_reference: "ticket:unsafe",
      input_digest: Agentkit::Harness.digest("unsafe"), model: "frozen-model",
      environment: { network: true }, output_contract: output_contract
    )
    callbacks = callbacks_for([])

    expect do
      Agentkit::Harness::Experiment.new(
        base: base_manifest, task: unsafe_task, proposer: callbacks[0],
        executor: callbacks[1], contrastor: callbacks[2], composer: callbacks[3]
      )
    end.to raise_error(Agentkit::HarnessExperimentError, /network-disabled/)
  end

  it "rejects composition decisions whose evidence was not produced by the probes" do
    revision = replacement(base_manifest)
    ungrounded = lambda do |_request|
      {
        action: "adopt", revision_id: revision.id,
        reasons: [{ summary: "looks better", evidence_refs: ["judge:invented"] }]
      }
    end
    callbacks = callbacks_for([revision], composition: ungrounded)

    experiment = Agentkit::Harness::Experiment.new(
      base: base_manifest, task: task, proposer: callbacks[0], executor: callbacks[1],
      contrastor: callbacks[2], composer: callbacks[3]
    )

    expect { experiment.run }.to raise_error(Agentkit::HarnessExperimentError, /unknown evidence/)
  end
end
