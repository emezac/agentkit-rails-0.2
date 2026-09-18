# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentkit::Flow::Topology do
  it "explains a flow with a stable digest, fan-out budget, effects and warnings" do
    items = [Struct.new(:id).new(1), Struct.new(:id).new(1)]
    flow = Class.new(Agentkit::Flow) do
      define_singleton_method(:name) { "TopologyFlow" }
      step(:diagnose, effect: :read_only, ordering: :strict, estimated_ms: 12) { true }
      parallel :review, over: items, branch_effect: :read_only,
                        conflict_key: ->(item) { item.id }, max_concurrency: 2,
                        estimated_ms: 20
      join :review, on: :all_settled, timeout: 5, on_timeout: :continue_with_partial
      map(:parts, over: [1, 2]) { |item| item }
      reduce(:parts, algebra: :associative, commutative: true) { |group| group.first }
    end

    plan = flow.explain_plan

    expect(plan[:definition_digest]).to start_with("sha256:")
    expect(flow.explain_plan[:definition_digest]).to eq(plan[:definition_digest])
    expect(plan[:max_fanout]).to eq(2)
    expect(plan[:fanout_budget]).to eq(2)
    expect(plan[:effects][:diagnose]).to eq(:read_only)
    expect(plan[:warnings]).to include(match(/conflict keys/), match(/contract test/))
  end

  it "rejects side-effecting parallel branches without an idempotency key" do
    flow = Class.new(Agentkit::Flow) do
      define_singleton_method(:name) { "UnsafeTopologyFlow" }
      parallel :write, over: [1], branch_effect: :side_effecting
      join :write
    end

    expect { flow.validate! }.to raise_error(Agentkit::FlowDefinitionError, /idempotency key/)
  end
end
