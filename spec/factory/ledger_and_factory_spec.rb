# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentkit::HITL do
  def propose(agent: "SalesAgent", type: "follow_up", payload: { "body" => "hola" })
    described_class.suggest!(type: type, title: "t", source_agent: agent, payload: payload)
  end

  describe "apply handlers" do
    it "runs the registered handler when a suggestion is accepted" do
      applied = []
      described_class.on("follow_up") { |s| applied << s.id }

      s = propose
      described_class.approve(s.id, actor: "human:1")

      expect(applied).to eq([s.id])
    end

    it "does not let a failing handler break the approval" do
      described_class.on("follow_up") { raise "handler exploded" }
      s = propose

      result = described_class.approve(s.id, actor: "human:1")

      expect(result.status).to eq("execution_unknown")
      expect(emitted("hitl.handler_failed")).not_to be_empty
    end
  end

  describe "rejection taxonomy" do
    it "requires a code from the closed list" do
      s = propose
      expect { described_class.reject(s.id, actor: "human:1", code: "porque no me gusta") }
        .to raise_error(Agentkit::UnknownRejectionCode, /wrong_target/)
    end

    it "accepts a valid code and records it" do
      s = propose
      described_class.reject(s.id, actor: "human:1", code: :wrong_target, note: "otra empresa")

      entry = described_class.ledger.entries.last
      expect(entry.rejection_code).to eq("wrong_target")
      expect(entry.decision).to eq("rejected")
    end
  end

  describe "idempotency" do
    it "does not create a second suggestion for the same key" do
      a = described_class.suggest!(type: "x", title: "t", source_agent: "A", idempotency_key: "k1")
      b = described_class.suggest!(type: "x", title: "t", source_agent: "A", idempotency_key: "k1")

      expect(b.id).to eq(a.id)
      expect(emitted("hitl.deduped")).not_to be_empty
    end

    it "rejects reuse of a key with different arguments" do
      described_class.suggest!(type: "x", title: "first", idempotency_key: "k1")

      expect do
        described_class.suggest!(type: "x", title: "different", idempotency_key: "k1")
      end.to raise_error(Agentkit::IdempotencyConflict, /different arguments/)
    end

    it "allows the same key in independent operation namespaces" do
      a = described_class.suggest!(type: "x", title: "a", idempotency_key: "k1",
                                   operation_namespace: "billing.refund")
      b = described_class.suggest!(type: "x", title: "b", idempotency_key: "k1",
                                   operation_namespace: "crm.follow_up")

      expect(a.id).not_to eq(b.id)
    end
  end

  describe "concurrent decisions" do
    it "records exactly one winner in the in-memory adapter" do
      suggestion = propose
      outcomes = Queue.new
      threads = [
        Thread.new do
          outcomes << described_class.approve(suggestion.id, actor: "human:1")
        rescue StandardError => e
          outcomes << e
        end,
        Thread.new do
          outcomes << described_class.reject(suggestion.id, actor: "human:2", code: :too_risky)
        rescue StandardError => e
          outcomes << e
        end
      ]
      threads.each(&:join)
      results = 2.times.map { outcomes.pop }

      expect(results.count { |item| item.is_a?(Agentkit::HITL::Suggestion) }).to eq(1)
      expect(results.count { |item| item.is_a?(Agentkit::DecisionConflict) }).to eq(1)
      expect(described_class.ledger.size).to eq(1)
    end
  end
end

RSpec.describe Agentkit::HITL::Ledger do
  let(:ledger) { Agentkit::HITL.ledger }

  def decide(decision, agent: "SalesAgent", mode: "human", code: :not_valuable, final: nil)
    s = Agentkit::HITL.suggest!(type: "follow_up", title: "t", source_agent: agent,
                                payload: { "body" => "original" })
    case decision
    when :accept then Agentkit::HITL.approve(s.id, actor: "human:1", mode: mode)
    when :edit   then Agentkit::HITL.approve(s.id, actor: "human:1", final_payload: final || { "body" => "edited" })
    when :reject then Agentkit::HITL.reject(s.id, actor: "human:1", code: code, mode: mode)
    when :expire then Agentkit::HITL.expire!(s.id)
    end
  end

  it "excludes auto-applied timeouts from the acceptance rate" do
    2.times { decide(:accept) }
    2.times { decide(:reject) }
    5.times { decide(:accept, mode: "auto") } # advisory timeouts

    # v0.1 counted these as approvals, which made every quality metric
    # optimistically wrong.
    expect(ledger.acceptance_rate(agent: "SalesAgent")).to eq(0.5)
  end

  it "separates clean acceptance from edited acceptance" do
    2.times { decide(:accept) }
    2.times { decide(:edit) }

    expect(ledger.acceptance_rate).to eq(1.0)
    expect(ledger.clean_acceptance_rate).to eq(0.5)
    expect(ledger.edit_magnitude.n).to eq(2)
  end

  it "profiles where an agent fails, not just how often" do
    3.times { decide(:reject, code: :wrong_target) }
    1.times { decide(:reject, code: :bad_timing) }

    profile = ledger.rejection_profile(agent: "SalesAgent")
    expect(profile["wrong_target"]).to eq(0.75)
    expect(profile["bad_timing"]).to eq(0.25)
  end

  it "measures the ignore rate" do
    2.times { decide(:accept) }
    2.times { decide(:expire) }

    expect(ledger.ignore_rate).to eq(0.5)
  end

  it "computes cost per accepted proposal" do
    Agentkit::LLM.complete("work") # generates cost
    decide(:accept)

    expect(ledger.cost_per_accepted).to be_a(Float)
  end
end

RSpec.describe Agentkit::Factory do
  def seed_rejections(agent:, code:, n:)
    n.times do
      s = Agentkit::HITL.suggest!(type: "t", title: "t", source_agent: agent, payload: { "a" => 1 })
      Agentkit::HITL.reject(s.id, actor: "human:1", code: code)
    end
  end

  describe "detectors are deterministic, with evidence" do
    it "detects a dominant rejection cluster" do
      seed_rejections(agent: "SupportAgent", code: :wrong_tone, n: 8)
      seed_rejections(agent: "SupportAgent", code: :bad_timing, n: 2)

      findings = described_class.diagnose!(window: 86_400)
      cluster  = findings.find { |f| f.detector == "rejection_cluster" }

      expect(cluster).not_to be_nil
      expect(cluster.subject).to eq("SupportAgent")
      expect(cluster.evidence[:code]).to eq("wrong_tone")
      expect(cluster.evidence[:share]).to eq(0.8)
      expect(cluster.suggested_level).to eq(:n2) # a prompt problem, not a code one
    end

    it "detects proposals nobody ever decides" do
      6.times do
        s = Agentkit::HITL.suggest!(type: "t", title: "t", source_agent: "NoisyAgent")
        Agentkit::HITL.expire!(s.id)
      end

      findings = described_class.diagnose!(window: 86_400)
      expect(findings.map(&:detector)).to include("ignored_proposals")
    end

    it "detects retrieval that costs money without influencing answers" do
      Agentkit.config.memory.embedding.policy = :immediate
      Agentkit::Memory.store("something", type: "insight")
      memories = [Agentkit::Memory.all.first]
      5.times { Agentkit::Memory.mark_used(memories, "an answer that cites nothing") }

      findings = described_class.diagnose!(window: 86_400)
      expect(findings.map(&:detector)).to include("retrieval_useless")
    end

    it "reports capability gaps as findings" do
      6.times { |i| Agentkit::Proposals.record_gap("hacé la cosa #{i}") }

      findings = described_class.diagnose!(window: 86_400)
      gap = findings.find { |f| f.detector == "capability_gap" }
      expect(gap.severity).to eq(:high)
    end
  end

  describe "promotion criteria" do
    it "refuses to promote without enough samples" do
      Agentkit::Prompt.define(:sales, version: 1) { "v1" }
      Agentkit::Prompt.define(:sales, version: 2, status: :draft) { "v2" }
      exp = described_class.experiment!(nil, target: "prompt:sales", control: 1, variant: 2, level: :n2)

      verdict = described_class.evaluate(exp)

      expect(verdict[:verdict]).to eq(:inconclusive)
      expect(verdict[:reason]).to eq(:insufficient_samples)
      expect(exp.status).to eq("running")
    end

    it "rolls back a variant that performs worse" do
      Agentkit::Prompt.define(:sales, version: 1) { "v1" }
      Agentkit::Prompt.define(:sales, version: 2, status: :draft) { "v2" }
      Agentkit.config.factory.promotion[:min_samples] = 5
      exp = described_class.experiment!(nil, target: "prompt:sales", control: 1, variant: 2, level: :n2)

      6.times { record_decision(exp: exp, arm: "control", version: 1, decision: :accept) }
      6.times { record_decision(exp: exp, arm: "variant", version: 2, decision: :reject) }

      verdict = described_class.evaluate(exp)

      expect(verdict[:verdict]).to eq(:rollback)
      expect(exp.status).to eq("rolled_back")
    end

    def record_decision(exp:, arm:, version:, decision:)
      s = Agentkit::HITL.suggest!(type: "t", title: "t", source_agent: "SalesAgent",
                                  prompt_id: :sales, prompt_version: version,
                                  experiment_id: exp.id, experiment_arm: arm)
      if decision == :accept
        Agentkit::HITL.approve(s.id, actor: "human:1")
      else
        Agentkit::HITL.reject(s.id, actor: "human:1", code: :not_valuable)
      end
    end
  end

  describe "the intervention ladder" do
    it "never executes a level 5 change" do
      finding = described_class::Finding.new(id: "f1", detector: "x", severity: :high,
                                             suggested_level: :n5, status: "open")

      expect { described_class.experiment!(finding, target: "code:foo", variant: "patch", level: :n5) }
        .to raise_error(Agentkit::ConfigurationError, /patches for review/)
    end

    it "emits a reviewable patch instead of writing to disk" do
      finding = described_class::Finding.new(id: "f1", detector: "slow_agent", severity: :high,
                                             summary: "too slow", suggested_level: :n5, status: "open")

      patch = described_class.patch!(finding, files: { "app/agents/x.rb" => "--- diff ---" })

      expect(patch[:status]).to eq("for_review")
      expect(patch[:branch]).to start_with("agentkit/factory/")
      expect(patch[:diff]).to have_key("app/agents/x.rb")
    end

    it "requires an explicit reversible adapter for N1" do
      expect {
        described_class.experiment!(nil, target: "parameter:model", control: "slow",
                                    variant: "fast", level: :n1)
      }.to raise_error(Agentkit::ConfigurationError, /No reversible intervention/)
    end

    it "applies and rolls back a registered N1 adapter" do
      transitions = []
      described_class::Interventions.register(
        "parameter:model", level: :n1,
        apply: ->(experiment) { transitions << [:apply, experiment.variant] },
        rollback: ->(experiment) { transitions << [:rollback, experiment.control] }
      )
      exp = described_class.experiment!(nil, target: "parameter:model", control: "slow",
                                        variant: "fast", level: :n1)

      described_class.rollback!(exp, reason: :guardrail)

      expect(transitions).to eq([[:apply, "fast"], [:rollback, "slow"]])
      expect(exp.status).to eq("rolled_back")
    end

    it "evaluates a global N1 adapter against its temporal baseline" do
      5.times do
        suggestion = Agentkit::HITL.suggest!(type: "t", title: "baseline",
                                             source_agent: "SalesAgent")
        Agentkit::HITL.reject(suggestion.id, actor: "human:1", code: :not_valuable)
      end
      Agentkit::Telemetry.emit("llm.call", dims: { agent: "SalesAgent" },
                                           measures: { cost_usd: 5.0 })

      described_class::Interventions.register(
        "parameter:model", level: :n1,
        apply: ->(_experiment) {}, adopt: ->(_experiment) {}, rollback: ->(_experiment) {}
      )
      promotion = Agentkit.config.factory.promotion
      promotion[:min_samples] = 5
      promotion[:min_effect] = 0.05
      promotion[:significance] = 0.90
      promotion[:min_duration] = 0
      promotion[:golden_set_gate] = :off
      exp = described_class.experiment!(
        nil, target: "parameter:model", control: "slow", variant: "fast", level: :n1,
        cohort: { agent_name: "SalesAgent" }
      )

      5.times do
        suggestion = Agentkit::HITL.suggest!(type: "t", title: "variant",
                                             source_agent: "SalesAgent")
        Agentkit::HITL.approve(suggestion.id, actor: "human:1")
      end
      Agentkit::Telemetry.emit("llm.call", dims: { agent: "SalesAgent" },
                                           measures: { cost_usd: 4.0 })

      verdict = described_class.evaluate(exp)

      expect(exp.results).to include("baseline_n" => 5, "baseline_acceptance" => 0.0)
      expect(verdict[:verdict]).to eq(:adopt)
      expect(verdict.dig(:cost, :ratio)).to eq(0.8)
      expect(exp.status).to eq("adopted")
    end

    it "refuses concurrent experiments whose cohorts overlap" do
      %w[parameter:first parameter:second].each do |target|
        described_class::Interventions.register(
          target, level: :n1,
          apply: ->(_experiment) {}, rollback: ->(_experiment) {}
        )
      end
      described_class.experiment!(
        nil, target: "parameter:first", control: "a", variant: "b", level: :n1,
        cohort: { agent_name: "SalesAgent" }
      )

      expect {
        described_class.experiment!(
          nil, target: "parameter:second", control: "a", variant: "b", level: :n1,
          cohort: { agent_name: "SalesAgent" }
        )
      }.to raise_error(Agentkit::ConfigurationError, /overlaps the cohort/)

      expect {
        described_class.experiment!(
          nil, target: "parameter:second", control: "a", variant: "b", level: :n1,
          cohort: { agent_name: "BillingAgent" }
        )
      }.not_to raise_error
    end
  end

  describe "golden set" do
    it "captures corrections as evaluation cases" do
      s = Agentkit::HITL.suggest!(type: "t", title: "t", source_agent: "SalesAgent",
                                  payload: { "body" => "original" })
      Agentkit::HITL.approve(s.id, actor: "human:1", final_payload: { "body" => "what the human wrote" })

      described_class.capture_golden!

      cases = described_class.golden_sets["SalesAgent"]
      expect(cases.size).to eq(1)
      expect(cases.first[:expected]).to eq({ "body" => "what the human wrote" })
      expect(cases.first[:label]).to eq("edited")
    end
  end

  describe "report" do
    it "renders the cycle report in markdown" do
      s = Agentkit::HITL.suggest!(type: "t", title: "t", source_agent: "SalesAgent")
      Agentkit::HITL.approve(s.id, actor: "human:1")

      md = described_class.report(window: 86_400)

      expect(md).to include("# AgentKit factory report", "## Agents", "SalesAgent")
    end
  end
end
