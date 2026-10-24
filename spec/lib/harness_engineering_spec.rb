# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Harness engineering contracts" do
  before do
    Agentkit.config.telemetry.backends = [:memory]
  end

  let(:goal) do
    Agentkit::Harness.define(
      id: "deploy-17",
      objective: "deploy a verified release",
      criteria: [{ id: "tests", description: "tests pass" }],
      constraints: [{ id: "no-prod-write", description: "production is unchanged", kind: :must_not }],
      scope: { include: ["app/**"], exclude: ["config/credentials.yml.enc"] },
      protected_resources: ["production/database"],
      required_approvals: ["deploy:production"],
      required_outputs: ["package"]
    )
  end

  it "makes scope, constraints, protected resources and approvals enforceable contract data" do
    progress = Agentkit::Harness.start(goal)
    progress.record_output("package", reference: "artifact:release.gem", value: "bytes")
    progress.record_evidence(criterion: "tests", verdict: :verified, source: "ci:17")

    expect(progress.evaluate!.missing_constraints).to eq(["no-prod-write"])
    expect(goal.approval_required_for?("deploy:production")).to be(true)
    expect(goal.scope["exclude"]).to eq(["config/credentials.yml.enc"])
    expect { progress.complete! }.to raise_error(Agentkit::HarnessIncomplete, /no-prod-write/)

    progress.record_evidence(
      criterion: "no-prod-write", verdict: :verified, source: "audit:17",
      summary: "no production calls observed"
    )
    expect { progress.complete! }.to raise_error(Agentkit::HarnessIncomplete, /deploy:production/)
    progress.record_approval(
      "deploy:production", actor: "principal:42", evidence_ref: "approval:991"
    )
    expect(progress.complete!).to be_complete
  end

  it "loads v1 checkpoints and upgrades their representation without weakening the digest check" do
    legacy_goal = {
      "id" => "legacy", "objective" => "finish legacy work",
      "criteria" => [{ "id" => "done", "description" => "done", "required" => true }],
      "required_outputs" => [], "max_steps" => 3, "metadata" => {}
    }
    payload = {
      "schema_version" => 1, "goal" => legacy_goal,
      "goal_digest" => Agentkit::Harness.digest(legacy_goal), "status" => "running",
      "step_count" => 0, "outputs" => {}, "evidence" => {}, "decisions" => [],
      "open_issues" => [], "next_action" => nil,
      "created_at" => Time.now.utc.iso8601(6), "updated_at" => Time.now.utc.iso8601(6)
    }

    restored = Agentkit::Harness::Progress.from_h(payload)

    expect(restored.goal.constraints).to be_empty
    expect(restored.to_h["schema_version"]).to eq(2)
  end

  it "selects context progressively and attaches freshness and digest evidence" do
    content = "release policy: tests and signatures are mandatory"
    map = Agentkit::Harness::ContextMap.new do
      source :release_policy, reference: "docs/release.md", topics: %w[release deploy],
                              observed_at: Time.now.utc, fresh_for: 60,
                              digest: Agentkit::Harness.digest(content)
      source :unrelated, reference: "docs/sales.md", topics: %w[sales]
    end

    compiled = map.compile(query: "deploy the release") do |source|
      source.id == "release_policy" ? content : "must not be loaded"
    end

    expect(compiled.selected_source_ids).to eq(["release_policy"])
    expect(compiled.fragment).to include("untrusted data", content)
    expect(compiled.evidence.first["digest"]).to eq(Agentkit::Harness.digest(content))
  end

  it "fails closed for stale required context" do
    map = Agentkit::Harness::ContextMap.new do
      source :policy, reference: "policy://release", required: true,
                      observed_at: Time.now.utc - 120, fresh_for: 10
    end

    expect { map.compile { "old policy" } }
      .to raise_error(Agentkit::StaleContextError, /stale/)
  end

  it "keeps verification read-only and applies a fail-closed review explicitly" do
    progress = Agentkit::Harness.start(goal)
    progress.record_output("package", reference: "artifact:release.gem")
    progress.record_evidence(criterion: "tests", verdict: :verified, source: "ci:17")
    frozen_request = false
    verifier = Agentkit::Harness::Verifier.new(
      name: "release-auditor",
      rejection_criteria: ["reject missing production audit"],
      reviewer: lambda do |request|
        frozen_request = request.frozen? && request["outputs"].frozen?
        {
          accepted: true,
          verdicts: [
            { criterion_id: "tests", verdict: "verified", summary: "CI evidence is valid" },
            { criterion_id: "no-prod-write", verdict: "verified", summary: "audit is clean" }
          ],
          reasons: []
        }
      end
    )

    review = verifier.verify(progress)

    expect(frozen_request).to be(true)
    expect(review).to be_accepted
    expect(progress.evidence).not_to have_key("no-prod-write")
    review.apply_to(progress)
    expect(progress.evidence.fetch("no-prod-write").source).to start_with("verifier:release-auditor:")
  end

  it "rejects verifier agents that expose mutating tools" do
    Agentkit::Skill.define(:unsafe_verifier_tools) do |skill|
      skill.tool(:write_report, effect: :internal) { |text:| text }
    end
    verifier_agent = Class.new(Agentkit::Agent) do
      uses_skills :unsafe_verifier_tools
      allow_tools :write_report
    end

    expect do
      Agentkit::Harness::Verifier.new(name: "unsafe", reviewer: verifier_agent)
    end.to raise_error(Agentkit::VerificationError, /read-only/)
  end

  it "emits a redacted harness receipt with pending approvals and a stable digest" do
    progress = Agentkit::Harness.start(goal)
    progress.record_output("package", reference: "artifact:release.gem", value: "secret bytes")
    progress.record_evidence(criterion: "tests", verdict: :verified, source: "ci:17")
    progress.record_evidence(criterion: "no-prod-write", verdict: :verified, source: "audit:17")

    receipt = Agentkit::Harness::Receipt.build(progress, risks: ["rollout latency"])

    expect(receipt[:complete]).to be(false)
    expect(receipt.dig(:approvals, :pending)).to eq(["deploy:production"])
    expect(receipt.to_s).not_to include("secret bytes")
    expect(receipt[:receipt_digest]).to match(/\Asha256:[0-9a-f]{64}\z/)
  end

  it "reports acceptance, recovery, unsupported claims and harness overhead" do
    context = Agentkit::Context.new(tenant_key: "acme")
    Agentkit::Harness.start(goal, context: context)
    Agentkit::Harness::Metrics.record_review(
      goal_id: goal.id, accepted: true, first_pass: true,
      human_minutes: 2.5, unsupported_claims: 1, context: context
    )
    Agentkit::Harness::Metrics.record_recovery(
      goal_id: goal.id, success: true, attempts: 2, context: context
    )
    Agentkit::Harness::Metrics.record_overhead(
      goal_id: goal.id, component: :verifier, duration_ms: 12, cost_usd: 0.02,
      context: context
    )

    summary = Agentkit::Harness::Metrics.summary(goal_id: goal.id, context: context)

    expect(summary[:first_pass_acceptance_rate]).to eq(1.0)
    expect(summary[:recovery_rate]).to eq(1.0)
    expect(summary[:unsupported_completion_claims]).to eq(1)
    expect(summary.dig(:harness_overhead_ms, :n)).to eq(1)
  end
end

RSpec.describe Agentkit::ToolContract do
  it "enforces schemas, preconditions and success evidence" do
    tool = described_class.new(
      name: :lookup,
      input_schema: {
        type: "object", properties: { id: { type: "integer" } },
        required: ["id"], additionalProperties: false
      },
      output_schema: {
        type: "object", properties: { name: { type: "string" } },
        required: ["name"], additionalProperties: false
      },
      preconditions: ->(inputs) { inputs[:id].positive? },
      success_evidence: ->(_result) { { source: "db:replica" } },
      callable: ->(id:) { { name: "record-#{id}" } }
    )

    execution = tool.invoke(id: 7)

    expect(execution.result).to eq(name: "record-7")
    expect(execution.evidence["source"]).to eq("db:replica")
    expect { tool.invoke(id: 0) }.to raise_error(Agentkit::ToolPreconditionFailed)
  end

  it "denies direct effects and performs only explicitly bounded recovery" do
    mutating = described_class.new(name: :publish, effect: :external, callable: -> { true })
    expect { mutating.call }.to raise_error(Agentkit::ToolExecutionDenied, /Actions/)

    calls = 0
    policy = Agentkit::RecoveryPolicy.new(rules: { transient: { backoff: 0 } })
    flaky = described_class.new(
      name: :flaky, retry: { attempts: 2, recovery_policy: policy },
      callable: lambda do
        calls += 1
        raise Agentkit::TransientError, "temporary" if calls == 1

        "ok"
      end
    )

    expect(flaky.invoke.result).to eq("ok")
    expect(calls).to eq(2)
  end

  it "provides the same introspection surface for capabilities" do
    capability = Agentkit::Capability.register(:read_status) do |cap|
      cap.effect :read_only
      cap.risk :read
      cap.inputs id: :integer
      cap.executor { |arguments| { id: arguments[:id], status: "ok" } }
    end

    contract = capability.tool_contract

    expect(contract).to be_read_only
    expect(contract.call(id: 3)).to eq(id: 3, status: "ok")
  end
end

RSpec.describe Agentkit::RecoveryPolicy do
  it "stops unchanged failure loops using a common failure taxonomy" do
    policy = described_class.new(repeated_threshold: 2)
    error = Agentkit::TransientError.new("upstream 503")
    fingerprint = policy.classify(error).fingerprint

    decision = policy.decide(error, attempt: 2, history: [fingerprint, fingerprint])

    expect(decision.failure.category).to eq(:repeated_unchanged)
    expect(decision.action).to eq(:stop)
  end
end
