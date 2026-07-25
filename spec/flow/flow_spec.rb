# frozen_string_literal: true

# The council example from the v2 design docs, plus the regression specs for
# the failure modes v0.1 had no way to express.
SPEC_CALLS = Hash.new(0)

RSpec.describe Agentkit::Flow do
  # Counts invocations so "3 branches, 3 calls" is verifiable — v0.1's
  # AgentTriggerable registered one callback per declaration and each callback
  # re-iterated every trigger, so three role bots produced nine invocations.
  def counting_agent(name, &body)
    Class.new(Agentkit::Agent) do
      define_singleton_method(:name) { name }
      define_method(:call) do |input|
        SPEC_CALLS[name] += 1
        body ? body.call(input) : "#{name}:#{input}"
      end
    end
  end

  before { SPEC_CALLS.clear }

  describe "sequential steps" do
    it "passes values forward and records every step" do
      flow = Class.new(described_class) do
        def self.name = "SeqFlow"
        input :seed
        step(:double) { |ctx| ctx.input[:seed] * 2 }
        step(:label)  { |ctx| "value=#{ctx[:double].value}" }
      end

      result = flow.call(seed: 21)

      expect(result).to be_ok
      expect(result.value).to eq("value=42")
      expect(result.run.steps.map(&:step_name)).to eq(%w[double label])
      expect(result.run.status).to eq("completed")
    end

    it "skips a guarded step without losing it from the record" do
      flow = Class.new(described_class) do
        def self.name = "GuardFlow"
        step(:always) { 1 }
        step(:never, if: ->(_ctx) { false }) { raise "must not run" }
      end

      result = flow.call
      expect(result).to be_ok
      expect(result.run.step(:never).status).to eq("skipped")
    end
  end

  describe "fan-out / fan-in" do
    it "runs each branch exactly once and releases the join through the barrier" do
      finance    = counting_agent("FinanceBot")
      accounting = counting_agent("AccountingBot")
      ceo        = counting_agent("CeoBot")

      flow = Class.new(described_class) do
        def self.name = "CouncilFlow"
        input :fact
        step(:observe) { |ctx| ctx.input[:fact] }
        parallel :council, over: [finance, accounting, ceo],
                           with: ->(ctx) { ctx[:observe].value }
        join :council, on: :all_complete
        step(:synthesize) { |ctx| ctx[:council].values.join(" | ") }
      end

      result = flow.call(fact: "Acme late")

      expect(result).to be_ok
      # Three branches → three invocations. Not nine.
      expect(SPEC_CALLS.values.sum).to eq(3)
      expect(result.value).to include("FinanceBot", "AccountingBot", "CeoBot")

      barrier = result.run.steps.find { |s| s.kind == "parallel" }
      expect(barrier.pending_count).to eq(0)
      expect(result.run.children_of(barrier.id).size).to eq(3)
    end

    it "keeps partial results when a branch fails under :all_settled" do
      good = counting_agent("GoodBot")
      bad  = counting_agent("BadBot") { raise "provider exploded" }

      flow = Class.new(described_class) do
        def self.name = "SettledFlow"
        step(:seed) { "x" }
        parallel :council, over: [good, bad], with: ->(_ctx) { "x" }
        join :council, on: :all_settled
        step(:collect) { |ctx| ctx[:council].values }
      end

      result = flow.call

      expect(result).to be_ok
      expect(result.value).to eq(["GoodBot:x"])
      expect(result.run.steps.select { |s| s.kind == "branch" }.map(&:status))
        .to contain_exactly("completed", "failed")
    end

    it "fails the run when a branch fails under :all_complete" do
      bad = counting_agent("BadBot") { raise "nope" }

      flow = Class.new(described_class) do
        def self.name = "StrictJoinFlow"
        step(:seed) { "x" }
        parallel :council, over: [bad], with: ->(_ctx) { "x" }
        join :council, on: :all_complete
        step(:never) { raise "unreachable" }
      end

      result = flow.call
      expect(result).to be_err
      expect(result.run.status).to eq("failed")
    end

    it "emits a join resolution event with the branch counts" do
      agent = counting_agent("Bot")
      flow = Class.new(described_class) do
        def self.name = "JoinTelemetryFlow"
        step(:seed) { "x" }
        parallel :p, over: [agent, agent], with: ->(_ctx) { "x" }
        join :p, on: :all_complete
      end

      flow.call
      event = emitted("flow.join.resolve").last
      expect(event.measures[:branches]).to eq(2)
      expect(event.measures[:failed]).to eq(0)
    end
  end

  describe "idempotency" do
    it "does not re-execute a step that already completed (job redelivery)" do
      calls = 0
      flow = Class.new(described_class) do
        def self.name = "ResumeFlow"
        step(:once) { calls += 1 }
      end

      first = flow.call
      run   = first.run

      # Simulate a redelivered job: same run, executor invoked again.
      Agentkit::Flow::Executor.new(definition: flow.definition, run: run,
                                   store: flow.store_for, context: Agentkit::Context.resolve,
                                   input: {}).call

      expect(calls).to eq(1)
      expect(emitted("flow.step.replayed")).not_to be_empty
    end

    it "returns the finished run instead of starting a duplicate" do
      runs = 0
      flow = Class.new(described_class) do
        def self.name = "IdempotentFlow"
        input :invoice_id
        idempotency ->(input) { "invoice:#{input[:invoice_id]}" }
        step(:work) { runs += 1 }
      end

      flow.call(invoice_id: 7)
      flow.call(invoice_id: 7)

      expect(runs).to eq(1)
    end
  end

  describe "retries" do
    it "retries a transient failure and then succeeds" do
      attempts = 0
      flow = Class.new(described_class) do
        def self.name = "RetryFlow"
        step(:flaky, retry: { attempts: 3 }) do
          attempts += 1
          raise Agentkit::TransientError, "rate limited" if attempts < 3

          "ok"
        end
      end

      result = flow.call
      expect(result).to be_ok
      expect(attempts).to eq(3)
      expect(result.run.step(:flaky).attempt_count).to eq(3)
    end
  end

  describe "loop_until" do
    it "stops as soon as the condition holds and records every iteration" do
      flow = Class.new(described_class) do
        def self.name = "NegotiationFlow"
        loop_until :negotiate, max: 4, until: ->(ctx) { ctx[:validate].value[:conflicts].zero? } do
          step(:propose) { |ctx| (ctx[:propose]&.value || 0) + 1 }
          step(:validate) { |ctx| { conflicts: ctx[:propose].value >= 3 ? 0 : 1 } }
        end
      end

      result = flow.call

      expect(result).to be_ok
      expect(result.run.steps_named("propose").size).to eq(3)
      expect(result.run.steps.map(&:step_key)).to include("propose:1", "propose:3")
    end

    it "honours the max even when the condition never holds" do
      flow = Class.new(described_class) do
        def self.name = "RunawayFlow"
        loop_until :spin, max: 2, until: ->(_ctx) { false } do
          step(:tick) { 1 }
        end
      end

      flow.call
      expect(Agentkit::Flow.store_for.runs.last.steps_named("tick").size).to eq(2)
    end
  end

  describe "map / reduce" do
    it "reduces in a tree instead of a chain" do
      flow = Class.new(described_class) do
        def self.name = "SummaryFlow"
        input :chunks
        map(:parts, over: ->(ctx) { ctx.input[:chunks] }) { |chunk| chunk.upcase }
        reduce(:parts, chunk: 3) { |group| group.join("+") }
      end

      result = flow.call(chunks: %w[a b c d e f g])

      expect(result).to be_ok
      expect(result.value).to include("A")
      event = emitted("flow.reduce").last
      expect(event.measures[:inputs]).to eq(7)
      expect(event.measures[:levels]).to eq(2) # 7 → 3 → 1
    end
  end

  describe "human gates" do
    it "suspends the run and resumes it when a human approves" do
      applied = false
      flow = Class.new(described_class) do
        def self.name = "GateFlow"
        step(:prepare) { "draft" }
        human_gate :approve, type: "council_recommendation"
        step(:apply, if: ->(ctx) { ctx[:approve].approved? }) { applied = true }
      end

      pending_result = flow.call
      expect(pending_result).to be_err
      expect(pending_result.error).to be_a(Agentkit::PendingHumanApproval)
      expect(applied).to be(false)

      run = Agentkit::Flow.store_for.runs.last
      expect(run.status).to eq("waiting_human")

      suggestion = Agentkit::HITL.pending.find { |s| s.gate_key&.include?("approve") }
      expect(suggestion).not_to be_nil
      Agentkit::HITL.approve(suggestion.id, actor: "human:1")

      flow.resume(run.run_id)

      expect(applied).to be(true)
      expect(Agentkit::Flow.store_for.runs.last.status).to eq("completed")
    end

    it "lets a spec drive the gate without a UI" do
      Agentkit::HITL.auto_approve!(type: "flow_gate")
      reached = false

      flow = Class.new(described_class) do
        def self.name = "AutoGateFlow"
        step(:prepare) { "draft" }
        human_gate :approve
        step(:apply) { reached = true }
      end

      expect(flow.call).to be_ok
      expect(reached).to be(true)
    end
  end

  describe "compensation (saga)" do
    it "undoes completed steps in reverse order" do
      undone = []
      flow = Class.new(described_class) do
        def self.name = "SagaFlow"
        step(:charge)  { "charged" }
        step(:render)  { "rendered" }
        step(:assemble) { raise "assembly failed" }
        compensate :charge, with: ->(_ctx) { undone << :charge }
        compensate :render, with: ->(_ctx) { undone << :render }
      end

      result = flow.call

      expect(result).to be_err
      expect(undone).to eq(%i[render charge])
      expect(Agentkit::Flow.store_for.runs.last.status).to eq("compensated")
    end

    it "runs on_error handlers before compensating" do
      seen = []
      flow = Class.new(described_class) do
        def self.name = "ErrorHandlerFlow"
        step(:boom) { raise "kaboom" }
        on_error ->(_ctx, err) { seen << err.message }
      end

      flow.call
      expect(seen.first).to include("kaboom")
    end
  end

  describe "static validation" do
    it "rejects a fan-out that is never joined" do
      flow = Class.new(described_class) do
        def self.name = "UnjoinedFlow"
        parallel :branches, over: [1, 2]
      end

      expect { flow.validate! }.to raise_error(Agentkit::FlowDefinitionError, /never joined/)
    end

    it "rejects a join with no matching parallel" do
      flow = Class.new(described_class) do
        def self.name = "OrphanJoinFlow"
        step(:a) { 1 }
        join :ghost, on: :all_complete
      end

      expect { flow.validate! }.to raise_error(Agentkit::FlowDefinitionError, /no matching parallel/)
    end

    it "rejects a compensation for an unknown step" do
      flow = Class.new(described_class) do
        def self.name = "BadCompFlow"
        step(:a) { 1 }
        compensate :nonexistent, with: -> {}
      end

      expect { flow.validate! }.to raise_error(Agentkit::FlowDefinitionError, /unknown step/)
    end

    it "rejects duplicate step names" do
      flow = Class.new(described_class) do
        def self.name = "DupFlow"
        step(:a) { 1 }
        step(:a) { 2 }
      end

      expect { flow.validate! }.to raise_error(Agentkit::FlowDefinitionError, /duplicate/)
    end
  end

  describe "telemetry" do
    it "records cost and duration per step and rolls it up to the run" do
      flow = Class.new(described_class) do
        def self.name = "CostFlow"
        step(:think) { Agentkit::LLM.complete("hello", model: :default) }
      end

      result = flow.call

      expect(emitted("flow.run.started")).not_to be_empty
      expect(emitted("flow.step.completed").first.dims[:flow]).to eq("CostFlow")
      expect(result.run.steps_completed).to eq(1)
    end
  end
end

RSpec.describe "Agentkit::Flow tolerant steps" do
  it "keeps going when a non-essential step fails" do
    flow = Class.new(Agentkit::Flow) do
      def self.name = "DegradingFlow"
      step(:optional, on_error: :continue) { raise "provider down" }
      step(:required) { |ctx| ctx[:optional].value.nil? ? "degraded" : "full" }
    end

    result = flow.call

    expect(result).to be_ok
    expect(result.value).to eq("degraded")
    expect(result.run.status).to eq("completed")
    expect(result.run.step(:optional).status).to eq("failed")
    expect(result.run.step(:optional).error).to include("provider down")
  end

  it "still fails the run for a step that is not marked tolerant" do
    flow = Class.new(Agentkit::Flow) do
      def self.name = "StrictDegradingFlow"
      step(:essential) { raise "provider down" }
      step(:never) { "unreachable" }
    end

    expect(flow.call).to be_err
  end
end
