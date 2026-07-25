# frozen_string_literal: true

require "rails_helper"

# The async path against the real barrier.
#
# The unit suite proves the algorithm with a Mutex-guarded Hash. That is not
# evidence about Postgres: the production barrier is an `UPDATE … RETURNING`,
# and the whole design rests on it decrementing exactly once per branch.
RSpec.describe "Async flow over ActiveRecord", :integration do
  let(:account) { account! }

  def queue!
    Agentkit.config.flow.dispatcher = :test
    Agentkit::Flow.dispatcher = nil
    Agentkit::Flow.dispatcher
  end

  after do
    Agentkit.config.flow.dispatcher = :active_job
    Agentkit::Flow.dispatcher = nil
  end

  it "parks the run with the barrier open and one job per branch" do
    queue = queue!
    widget = Widget.create!(account: account, name: "async-1")

    run = with_account(account) { DummyFlow.perform_later(widget: widget) }
    queue.drain(limit: 1)

    row = Agentkit::RunRecord.find(run.id)
    barrier = Agentkit::RunStepRecord.find_by(run_id: run.id, kind: "parallel")

    expect(row.status).to eq("waiting_join")
    expect(barrier.pending_count).to eq(3)
    expect(queue.pending.count { |j| j.kind == :branch }).to eq(3)
    expect(Agentkit::RunStepRecord.where(run_id: run.id, step_name: "collect")).to be_empty
  end

  %i[fifo lifo random].each do |order|
    it "releases the join exactly once when branches close #{order}" do
      queue = queue!
      widget = Widget.create!(account: account, name: "async-#{order}")

      run = with_account(account) { DummyFlow.perform_later(widget: widget) }
      queue.drain(order: order)

      row = Agentkit::RunRecord.find(run.id)
      expect(row.status).to eq("completed")

      barrier = Agentkit::RunStepRecord.find_by(run_id: run.id, kind: "parallel")
      expect(barrier.pending_count).to eq(0)
      # The join node ran once, not once per branch.
      expect(Agentkit::RunStepRecord.where(run_id: run.id, step_name: "fan_join").count).to eq(1)
    end
  end

  # The guarantee the design rests on: `UPDATE … WHERE status <> 'completed'`
  # affects zero rows on a redelivery, so the counter is never decremented twice.
  it "never double-decrements the barrier when every job is delivered twice" do
    queue = queue!
    widget = Widget.create!(account: account, name: "async-dup")

    run = with_account(account) { DummyFlow.perform_later(widget: widget) }
    queue.drain(duplicate: true)

    barrier = Agentkit::RunStepRecord.find_by(run_id: run.id, kind: "parallel")
    expect(barrier.pending_count).to eq(0)      # not -3
    expect(Agentkit::RunRecord.find(run.id).status).to eq("completed")

    # Three branches, three echoed memories — not six.
    echoes = Agentkit::MemoryRecord.where(source_agent: "EchoAgent",
                                          tenant_key: account.tenant_key).count
    expect(echoes).to eq(3)
  end

  it "resumes from the database after the process that started it is gone" do
    queue = queue!
    widget = Widget.create!(account: account, name: "async-resume")
    run = with_account(account) { DummyFlow.perform_later(widget: widget) }
    queue.drain(limit: 1)

    # Everything the worker needs is in the tables: drop every in-memory handle
    # and rebuild the store from scratch, the way a second process would.
    Agentkit::Flow.shared_store = nil
    branch_ids = Agentkit::RunStepRecord.where(run_id: run.id, kind: "branch").pluck(:id)
    branch_ids.each { |id| Agentkit::Flow::Worker.run_branch(run.run_id, id) }

    # The branch that closed the barrier enqueued the continuation rather than
    # running it inline — that is the point of the design, so drain it.
    queue.drain

    expect(Agentkit::RunRecord.find(run.id).status).to eq("completed")
    expect(Agentkit::RunStepRecord.find_by(run_id: run.id, step_name: "collect").status)
      .to eq("completed")
  end

  it "does not re-execute completed steps on a repeated advance" do
    queue = queue!
    widget = Widget.create!(account: account, name: "async-idem")
    run = with_account(account) { DummyFlow.perform_later(widget: widget) }
    queue.drain

    before = Agentkit::MemoryRecord.where(source_agent: "EchoAgent").count
    3.times { Agentkit::Flow::Worker.advance(run.run_id) }

    expect(Agentkit::MemoryRecord.where(source_agent: "EchoAgent").count).to eq(before)
  end

  it "cancels stragglers and continues when the join times out" do
    queue = queue!
    widget = Widget.create!(account: account, name: "async-timeout")

    partial_flow = Class.new(Agentkit::Flow) do
      def self.name = "ARPartialFlow"
      input :widget
      step(:prepare) { |ctx| ctx.input[:widget].name }
      parallel :fan, over: [EchoAgent, EchoAgent], with: ->(ctx) { ctx[:prepare].value }
      join :fan, on: :all_settled, timeout: 30, on_timeout: :continue_with_partial
      step(:collect) { |ctx| ctx[:fan].values.size }
    end

    run = with_account(account) { partial_flow.perform_later(widget: widget) }
    queue.drain(limit: 1)

    first = queue.pending.find { |j| j.kind == :branch }
    queue.run(first)
    queue.jobs.delete(first)

    queue.fire_timeouts!
    queue.drain

    row = Agentkit::RunRecord.find(run.id)
    expect(row.status).to eq("completed")
    statuses = Agentkit::RunStepRecord.where(run_id: run.id, kind: "branch").pluck(:status)
    expect(statuses).to include("cancelled")
  end

  it "offloads an oversized payload into agentkit_artifacts" do
    Agentkit.config.flow.max_inline_payload = 512
    big = "x" * 4_000

    flow = Class.new(Agentkit::Flow) do
      def self.name = "ARArtifactFlow"
      step(:produce) { big }
      step(:consume) { |ctx| ctx[:produce].value.length }
    end

    result = flow.call

    expect(result.value).to eq(4_000)
    expect(Agentkit::ArtifactRecord.count).to be >= 1
    stored = Agentkit::RunStepRecord.find_by(run_id: result.run.id, step_key: "produce")
    expect(stored.output["result"]).to have_key("$artifact")
  ensure
    Agentkit.config.flow.max_inline_payload = 64 * 1024
  end
end
