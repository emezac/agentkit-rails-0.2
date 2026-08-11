# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Factory persistence and proof gates", :integration do
  def finding!(detector: "latency", subject: "checkout", level: :n2)
    finding = Agentkit::Factory::Finding.new(
      id: SecureRandom.uuid, detector: detector, severity: :high,
      subject: subject, summary: "measured problem", evidence: { p95: 20_000 },
      suggested_level: level, status: "open", created_at: Time.current
    )
    Agentkit::Factory.record_finding(finding).first
  end

  def define_sales_prompts
    Agentkit::Prompt.define(:sales, version: 1) { "control" }
    Agentkit::Prompt.define(:sales, version: 2, status: :draft) { "variant" }
  end

  def decide(experiment:, arm:, version:, accepted:)
    suggestion = Agentkit::HITL.suggest!(
      type: "proposal", title: "proposal", source_agent: "EchoAgent",
      prompt_id: :sales, prompt_version: version,
      experiment_id: experiment.id, experiment_arm: arm
    )
    if accepted
      Agentkit::HITL.approve(suggestion.id, actor: "human:1")
    else
      Agentkit::HITL.reject(suggestion.id, actor: "human:1", code: :not_valuable)
    end
  end

  it "persists every experiment and finding transition across reloads" do
    define_sales_prompts
    finding = finding!
    Agentkit::Factory.resolve_finding!(finding.id, "accepted", actor: "owner:1",
                                                              reason: "worth testing")

    experiment = Agentkit::Factory.experiment!(
      finding.id, target: "prompt:sales", control: 1, variant: 2, level: :n2,
      cohort: { agent_name: "EchoAgent" }
    )

    expect(Agentkit::ExperimentRecord.find(experiment.id)).to have_attributes(status: "running")
    expect(Agentkit::FindingRecord.find(finding.id)).to have_attributes(status: "experimenting")

    reloaded = Agentkit::Factory.experiments.find { |candidate| candidate.id == experiment.id }
    Agentkit::Factory.rollback!(reloaded, reason: :manual_safety_stop)

    row = Agentkit::ExperimentRecord.find(experiment.id)
    expect(row).to have_attributes(status: "rolled_back")
    expect(row.finished_at).to be_present
    expect(row.results["rollback_reason"]).to eq("manual_safety_stop")
    expect(Agentkit::FindingRecord.find(finding.id)).to have_attributes(status: "accepted")
  end

  it "persists inconclusive evaluations instead of changing only the struct" do
    define_sales_prompts
    experiment = Agentkit::Factory.experiment!(
      nil, target: "prompt:sales", control: 1, variant: 2, level: :n2
    )

    verdict = Agentkit::Factory.evaluate(experiment)
    row = Agentkit::ExperimentRecord.find(experiment.id)

    expect(verdict).to include(verdict: :inconclusive, reason: :insufficient_samples)
    expect(row.status).to eq("running")
    expect(row.results).to include("verdict" => "inconclusive",
                                   "reason" => "insufficient_samples")
    expect(row.last_evaluated_at).to be_present
  end

  it "deduplicates active findings and records recurrence evidence" do
    first = finding!
    second = finding!

    expect(second.id).to eq(first.id)
    expect(Agentkit::FindingRecord.where(fingerprint: first.fingerprint).count).to eq(1)
    expect(Agentkit::FindingRecord.find(first.id).occurrence_count).to eq(2)
  end

  it "persists golden cases and survives a factory reset" do
    suggestion = Agentkit::HITL.suggest!(
      type: "proposal", title: "proposal", source_agent: "EchoAgent",
      payload: { "body" => "original" }
    )
    Agentkit::HITL.approve(suggestion.id, actor: "human:1",
                          final_payload: { "body" => "human correction" })

    expect(Agentkit::Factory.capture_golden!).to eq(1)
    captured = Agentkit::Factory.golden_sets["EchoAgent"].first
    Agentkit::Factory.freeze_golden!("EchoAgent", captured.id)
    Agentkit::Factory.reset!

    reloaded = Agentkit::Factory.golden_sets["EchoAgent"].first
    expect(reloaded.expected).to eq("body" => "human correction")
    expect(reloaded.frozen).to be(true)
  end

  it "isolates cohorts and adopts only after statistical, golden and cost proof" do
    define_sales_prompts
    promotion = Agentkit.config.factory.promotion
    promotion[:min_samples] = 10
    promotion[:min_effect] = 0.05
    promotion[:significance] = 0.90
    promotion[:min_duration] = 0

    Agentkit::GoldenCaseRecord.create!(
      agent_name: "EchoAgent", suggestion_id: 99_999,
      input: { "body" => "x" }, expected: { "body" => "y" },
      label: "edited", reviewed: true
    )
    Agentkit::Factory.register_golden_runner { |_experiment, _cases| [] }

    experiment = Agentkit::Factory.experiment!(
      nil, target: "prompt:sales", control: 1, variant: 2, level: :n2,
      cohort: { agent_name: "EchoAgent" }
    )
    10.times { decide(experiment: experiment, arm: "control", version: 1, accepted: false) }
    10.times { decide(experiment: experiment, arm: "variant", version: 2, accepted: true) }

    # Same prompt versions, but no experiment id: these rows must not enter the
    # denominator or reverse the result.
    20.times do
      suggestion = Agentkit::HITL.suggest!(type: "proposal", title: "unrelated",
                                           source_agent: "EchoAgent",
                                           prompt_id: :sales, prompt_version: 2)
      Agentkit::HITL.reject(suggestion.id, actor: "human:1", code: :not_valuable)
    end

    %w[control variant].each do |arm|
      Agentkit::Telemetry.emit("llm.call",
                               dims: { experiment_id: experiment.id, experiment_arm: arm },
                               measures: { cost_usd: arm == "control" ? 1.0 : 1.05 })
    end

    verdict = Agentkit::Factory.evaluate(experiment)

    expect(verdict[:verdict]).to eq(:adopt)
    expect(Agentkit::ExperimentRecord.find(experiment.id).status).to eq("adopted")
    expect(Agentkit::Prompt.active_version(:sales)).to eq(2)
  end

  it "evaluates a persisted global N1 experiment against a temporal baseline" do
    promotion = Agentkit.config.factory.promotion
    original = promotion.dup
    Agentkit::Factory::Interventions.register(
      "parameter:model", level: :n1,
      apply: ->(_experiment) {}, adopt: ->(_experiment) {}, rollback: ->(_experiment) {}
    )
    promotion[:min_samples] = 10
    promotion[:min_effect] = 0.05
    promotion[:significance] = 0.90
    promotion[:min_duration] = 0
    promotion[:golden_set_gate] = :off

    10.times do
      suggestion = Agentkit::HITL.suggest!(type: "proposal", title: "baseline",
                                           source_agent: "EchoAgent")
      Agentkit::HITL.reject(suggestion.id, actor: "human:1", code: :not_valuable)
    end
    Agentkit::Telemetry.emit("llm.call", dims: { agent: "EchoAgent" },
                                         measures: { cost_usd: 10.0 })
    experiment = Agentkit::Factory.experiment!(
      nil, target: "parameter:model", control: "slow", variant: "fast", level: :n1,
      cohort: { agent_name: "EchoAgent" }
    )

    10.times do
      suggestion = Agentkit::HITL.suggest!(type: "proposal", title: "variant",
                                           source_agent: "EchoAgent")
      Agentkit::HITL.approve(suggestion.id, actor: "human:1")
    end
    Agentkit::Telemetry.emit("llm.call", dims: { agent: "EchoAgent" },
                                         measures: { cost_usd: 9.0 })

    verdict = Agentkit::Factory.evaluate(experiment)

    expect(verdict).to include(verdict: :adopt)
    expect(verdict.dig(:cost, :ratio)).to eq(0.9)
    expect(Agentkit::ExperimentRecord.find(experiment.id)).to have_attributes(status: "adopted")
  ensure
    promotion&.replace(original) if original
  end

  it "restores prompt canaries and adopted versions in another process" do
    define_sales_prompts
    account = account!(name: "Canary tenant")
    context = Agentkit::Context.new(account: account)
    experiment = Agentkit::Factory.experiment!(
      nil, target: "prompt:sales", control: 1, variant: 2, level: :n2,
      traffic_pct: 100, bucket_by: :account,
      cohort: { agent_name: "EchoAgent", prompt_id: "sales" }
    )

    # A new web process rebuilds code definitions but has no in-memory canary.
    Agentkit::Prompt.reset!
    define_sales_prompts
    text, version = Agentkit::Prompt.render(:sales, context)
    assignment = Agentkit::Prompt.experiment_assignment(:sales, version: version, ctx: context)

    expect([ text, version ]).to eq([ "variant", 2 ])
    expect(assignment).to include(experiment_id: experiment.id, experiment_arm: "variant")

    Agentkit::Factory.adopt!(experiment)
    Agentkit::Prompt.reset!
    define_sales_prompts

    expect(Agentkit::Prompt.active_version(:sales)).to eq(2)
    expect(Agentkit::Prompt.render(:sales, context)).to eq([ "variant", 2 ])
  end
end
