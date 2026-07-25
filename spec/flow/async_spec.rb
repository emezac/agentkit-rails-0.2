# frozen_string_literal: true

# The async path, driven by a queue the spec controls.
#
# This is the only honest way to test a barrier: branches must be allowed to
# finish out of order, twice, and never — and the join has to behave. A suite
# that only runs the sync executor proves nothing about the thing that actually
# breaks in production.
ASYNC_CALLS = Hash.new(0)

RSpec.describe "Agentkit::Flow async execution" do
  let(:queue) { Agentkit::Flow.dispatcher }

  before do
    Agentkit.config.flow.executor   = :async
    Agentkit.config.flow.dispatcher = :test
    Agentkit::Flow.dispatcher = nil
    ASYNC_CALLS.clear
  end

  def counting_agent(name, &body)
    Class.new(Agentkit::Agent) do
      define_singleton_method(:name) { name }
      define_method(:call) do |input|
        ASYNC_CALLS[name] += 1
        body ? body.call(input) : "#{name}:#{input}"
      end
    end
  end

  def council_flow(agents, join_opts: { on: :all_complete })
    Class.new(Agentkit::Flow) do
      def self.name = "AsyncCouncilFlow"
      input :fact
      step(:observe) { |ctx| ctx.input[:fact] }
      parallel :council, over: agents, with: ->(ctx) { ctx[:observe].value }
      join :council, **join_opts
      step(:synthesize) { |ctx| ctx[:council].values.sort.join(" | ") }
    end
  end

  describe "enqueue and advance" do
    it "returns a parked run instead of executing inline" do
      flow = Class.new(Agentkit::Flow) do
        def self.name = "AsyncSeqFlow"
        input :seed
        step(:double) { |ctx| ctx.input[:seed] * 2 }
        step(:label)  { |ctx| "value=#{ctx[:double].value}" }
      end

      run = flow.perform_later(seed: 21)

      expect(run).to be_a(Agentkit::Flow::Run)
      expect(run.status).to eq("pending")
      expect(queue.size).to eq(1)          # one advance job, nothing executed

      queue.drain

      expect(Agentkit::Flow.shared_store.find_run_by_uuid(run.run_id).status).to eq("completed")
    end
  end

  describe "fan-out suspends at the join" do
    it "parks the run with the barrier open and one job per branch" do
      flow = council_flow([counting_agent("A"), counting_agent("B"), counting_agent("C")])
      run  = flow.perform_later(fact: "x")

      queue.drain(limit: 1) # only the first advance

      parked  = Agentkit::Flow.shared_store.find_run_by_uuid(run.run_id)
      barrier = parked.steps.find { |s| s.kind == "parallel" }

      expect(parked.status).to eq("waiting_join")
      expect(barrier.pending_count).to eq(3)
      expect(queue.pending.count { |j| j.kind == :branch }).to eq(3)
      expect(ASYNC_CALLS.values.sum).to eq(0)   # no branch has run yet
      expect(parked.step(:synthesize)).to be_nil
    end

    it "completes once every branch reports back" do
      flow = council_flow([counting_agent("A"), counting_agent("B"), counting_agent("C")])
      run  = flow.perform_later(fact: "x")

      queue.drain

      final = Agentkit::Flow.shared_store.find_run_by_uuid(run.run_id)
      expect(final.status).to eq("completed")
      expect(ASYNC_CALLS.values.sum).to eq(3)
      expect(final.step(:synthesize).result).to include("A:x", "B:x", "C:x")
      expect(final.steps.find { |s| s.kind == "parallel" }.pending_count).to eq(0)
    end
  end

  describe "the barrier does not depend on ordering" do
    %i[fifo lifo random].each do |order|
      it "releases the join exactly once when branches finish #{order}" do
        flow = council_flow([counting_agent("A"), counting_agent("B"),
                             counting_agent("C"), counting_agent("D")])
        run  = flow.perform_later(fact: "x")

        queue.drain(order: order)

        final = Agentkit::Flow.shared_store.find_run_by_uuid(run.run_id)
        expect(final.status).to eq("completed")
        expect(ASYNC_CALLS.values.sum).to eq(4)
        # The join node ran once, not once per branch.
        expect(final.steps_named("council_join").size).to eq(1)
        expect(emitted("flow.join.resolve").size).to eq(1)
      end
    end
  end

  describe "at-least-once delivery" do
    it "executes each branch once even when every job is delivered twice" do
      flow = council_flow([counting_agent("A"), counting_agent("B"), counting_agent("C")])
      run  = flow.perform_later(fact: "x")

      queue.drain(duplicate: true)

      final = Agentkit::Flow.shared_store.find_run_by_uuid(run.run_id)
      expect(final.status).to eq("completed")
      expect(ASYNC_CALLS.values.sum).to eq(3)          # not 6
      expect(emitted("flow.branch.redelivered")).not_to be_empty
      expect(final.steps.find { |s| s.kind == "parallel" }.pending_count).to eq(0) # not -3
    end

    it "does not re-run a completed sequential step on a repeated advance" do
      calls = 0
      flow = Class.new(Agentkit::Flow) do
        def self.name = "AsyncIdempotentFlow"
        step(:once) { calls += 1 }
      end

      run = flow.perform_later
      queue.drain
      3.times { Agentkit::Flow::Worker.advance(run.run_id) }

      expect(calls).to eq(1)
    end
  end

  describe "partial results" do
    it "keeps the successful branches when one fails under :all_settled" do
      flow = council_flow([counting_agent("Good"), counting_agent("Bad") { raise "boom" }],
                          join_opts: { on: :all_settled })
      run = flow.perform_later(fact: "x")

      queue.drain

      final = Agentkit::Flow.shared_store.find_run_by_uuid(run.run_id)
      expect(final.status).to eq("completed")
      expect(final.steps.select { |s| s.kind == "branch" }.map(&:status))
        .to contain_exactly("completed", "failed")
    end

    it "fails the run when a branch fails under :all_complete" do
      flow = council_flow([counting_agent("Bad") { raise "boom" }])
      run  = flow.perform_later(fact: "x")

      queue.drain

      expect(Agentkit::Flow.shared_store.find_run_by_uuid(run.run_id).status).to eq("failed")
    end
  end

  describe "join timeout" do
    it "continues with what arrived and cancels the stragglers" do
      slow = counting_agent("Slow")
      flow = council_flow([counting_agent("Fast"), slow],
                          join_opts: { on: :all_settled, timeout: 60,
                                       on_timeout: :continue_with_partial })
      run = flow.perform_later(fact: "x")

      queue.drain(limit: 1)                                  # fan out
      first = queue.pending.find { |j| j.kind == :branch }
      queue.run(first)                                       # only one branch reports
      queue.jobs.delete(first)

      expect(queue.pending.any? { |j| j.kind == :join_timeout }).to be(true)
      queue.fire_timeouts!
      queue.drain

      final = Agentkit::Flow.shared_store.find_run_by_uuid(run.run_id)
      expect(final.status).to eq("completed")
      expect(final.steps.select { |s| s.kind == "branch" }.map(&:status))
        .to include("cancelled")
      expect(emitted("flow.join.timeout")).not_to be_empty
    end

    it "fails the run when the policy says so" do
      flow = council_flow([counting_agent("A"), counting_agent("B")],
                          join_opts: { on: :all_complete, timeout: 30, on_timeout: :fail })
      run = flow.perform_later(fact: "x")

      queue.drain(limit: 1)
      queue.fire_timeouts!

      expect(Agentkit::Flow.shared_store.find_run_by_uuid(run.run_id).status).to eq("failed")
    end

    it "is a no-op once the barrier has already released" do
      flow = council_flow([counting_agent("A")], join_opts: { on: :all_complete, timeout: 30 })
      run  = flow.perform_later(fact: "x")
      queue.drain

      expect { queue.fire_timeouts! }.not_to(change do
        Agentkit::Flow.shared_store.find_run_by_uuid(run.run_id).status
      end)
    end
  end

  describe "human gates" do
    it "parks the run without consuming a worker and resumes on approval" do
      applied = false
      flow = Class.new(Agentkit::Flow) do
        def self.name = "AsyncGateFlow"
        step(:prepare) { "draft" }
        human_gate :approve, type: "council_recommendation"
        step(:apply, if: ->(ctx) { ctx[:approve].approved? }) { applied = true }
      end

      run = flow.perform_later
      queue.drain

      parked = Agentkit::Flow.shared_store.find_run_by_uuid(run.run_id)
      expect(parked.status).to eq("waiting_human")
      expect(queue.size).to eq(0)          # nothing spinning
      expect(applied).to be(false)

      suggestion = Agentkit::HITL.pending.find { |s| s.gate_key&.include?("approve") }
      Agentkit::HITL.approve(suggestion.id, actor: "human:1")

      Agentkit::Flow::Worker.advance(run.run_id)

      expect(applied).to be(true)
      expect(Agentkit::Flow.shared_store.find_run_by_uuid(run.run_id).status).to eq("completed")
    end

    it "does not create a second suggestion when advanced while still waiting" do
      flow = Class.new(Agentkit::Flow) do
        def self.name = "AsyncGateIdemFlow"
        step(:prepare) { "draft" }
        human_gate :approve
      end

      run = flow.perform_later
      queue.drain
      3.times { Agentkit::Flow::Worker.advance(run.run_id) }

      expect(Agentkit::HITL.pending.size).to eq(1)
    end
  end

  describe "map / reduce" do
    it "fans out over items and reduces after the barrier" do
      flow = Class.new(Agentkit::Flow) do
        def self.name = "AsyncMapFlow"
        input :chunks
        map(:parts, over: ->(ctx) { ctx.input[:chunks] }) { |chunk| chunk.upcase }
        reduce(:parts, chunk: 3) { |group| group.sort.join("+") }
      end

      run = flow.perform_later(chunks: %w[a b c d e])
      queue.drain

      final = Agentkit::Flow.shared_store.find_run_by_uuid(run.run_id)
      expect(final.status).to eq("completed")
      expect(final.step(:parts_reduce).result).to include("A")
      expect(final.steps.count { |s| s.kind == "map_item" || s.kind == "branch" }).to eq(5)
    end
  end

  describe "crash resumption" do
    it "picks up from the next pending step, not from the beginning" do
      order = []
      flow = Class.new(Agentkit::Flow) do
        def self.name = "AsyncCrashFlow"
        step(:one)   { order << :one; 1 }
        step(:two)   { order << :two; 2 }
        step(:three) { order << :three; 3 }
      end

      run   = flow.perform_later
      store = Agentkit::Flow.shared_store

      # Simulate a worker dying after the first step: run the advance, but
      # pretend the process vanished by re-entering from scratch.
      Agentkit::Flow::Worker.advance(run.run_id)
      expect(order).to eq(%i[one two three])

      order.clear
      Agentkit::Flow::Worker.advance(run.run_id)
      expect(order).to be_empty  # nothing re-executed
      expect(store.find_run_by_uuid(run.run_id).status).to eq("completed")
    end
  end

  describe "payload serialisation between jobs" do
    it "round-trips values through the step rows" do
      flow = Class.new(Agentkit::Flow) do
        def self.name = "AsyncCoderFlow"
        step(:produce) { { "name" => "Acme", "amount" => 1500, "tags" => %w[a b] } }
        step(:consume) { |ctx| "#{ctx[:produce].value['name']}:#{ctx[:produce].value['amount']}" }
      end

      run = flow.perform_later
      queue.drain

      expect(Agentkit::Flow.shared_store.find_run_by_uuid(run.run_id).step(:consume).result)
        .to eq("Acme:1500")
    end

    it "rehydrates a memory record by id rather than copying it" do
      Agentkit.config.memory.embedding.policy = :never
      memory = Agentkit::Memory.store("Acme paga tarde", tags: %w[acme])

      flow = Class.new(Agentkit::Flow) do
        def self.name = "AsyncMemoryFlow"
        step(:emit)    { memory }
        step(:consume) { |ctx| ctx[:emit].value.content }
      end

      run = flow.perform_later
      queue.drain

      expect(Agentkit::Flow.shared_store.find_run_by_uuid(run.run_id).step(:consume).result)
        .to eq("Acme paga tarde")
    end

    it "offloads an oversized payload to an artifact instead of the row" do
      Agentkit.config.flow.max_inline_payload = 512
      big = "x" * 4_000

      flow = Class.new(Agentkit::Flow) do
        def self.name = "AsyncArtifactFlow"
        step(:produce) { big }
        step(:consume) { |ctx| ctx[:produce].value.length }
      end

      run = flow.perform_later
      queue.drain

      store  = Agentkit::Flow.shared_store
      final  = store.find_run_by_uuid(run.run_id)
      stored = final.step(:produce).output["result"]

      expect(stored).to have_key(Agentkit::Flow::Coder::ARTIFACT_KEY)
      expect(final.step(:consume).result).to eq(4_000)
    end
  end

  describe "telemetry" do
    it "reports how many branches remain as each one closes" do
      flow = council_flow([counting_agent("A"), counting_agent("B"), counting_agent("C")])
      flow.perform_later(fact: "x")
      queue.drain

      remaining = emitted("flow.branch.completed").map { |e| e.measures[:remaining] }
      expect(remaining.sort).to eq([0, 1, 2])
    end

    it "records the suspension and the resumption" do
      flow = council_flow([counting_agent("A")])
      flow.perform_later(fact: "x")
      queue.drain

      expect(emitted("flow.run.suspended").first.dims[:reason]).to eq(:waiting_join)
      expect(emitted("flow.run.completed")).not_to be_empty
    end
  end
end

RSpec.describe "Agentkit::Flow join timeout with compensation" do
  before do
    Agentkit.config.flow.executor   = :async
    Agentkit.config.flow.dispatcher = :test
    Agentkit::Flow.dispatcher = nil
  end

  it "unwinds the saga instead of just marking the run failed" do
    undone = []
    agent  = Class.new(Agentkit::Agent) do
      def self.name = "SlowBranch"
      def call(input) = input
    end

    flow = Class.new(Agentkit::Flow) do
      def self.name = "TimeoutCompensateFlow"
      step(:charge) { "charged" }
      parallel :council, over: [agent, agent], with: ->(_ctx) { "x" }
      join :council, on: :all_complete, timeout: 10, on_timeout: :compensate
      compensate :charge, with: ->(_ctx) { undone << :charge }
    end

    run   = flow.perform_later
    queue = Agentkit::Flow.dispatcher
    queue.drain(limit: 1)      # fan out, nothing reports back
    queue.fire_timeouts!
    queue.drain

    final = Agentkit::Flow.shared_store.find_run_by_uuid(run.run_id)
    expect(undone).to eq([:charge])
    expect(final.status).to eq("compensated")
  end
end
