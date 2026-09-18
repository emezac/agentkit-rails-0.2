# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Adaptive exploration persistence", :integration do
  it "persists replay worlds and scopes them by tenant" do
    Agentkit.config.exploration.enabled = true
    Agentkit.config.exploration.store = :active_record
    Agentkit::Exploration.store = Agentkit::Exploration::Stores::ActiveRecord.new
    account = account!(name: "Explore A")
    other = account!(name: "Explore B")

    world = with_account(account) do
      Agentkit::Exploration.run(
        objective: "find a better support policy", policy: Agentkit::Exploration::Policies::Portfolio.new,
        generator: ->(**) { { candidate: "digest me" } },
        evaluator: ->(_) { { score: 1.0 } }, evaluator_id: "support-eval-v1",
        max_rounds: 1
      )
    end

    expect(Agentkit::ExplorationWorldRecord.where(tenant_key: "account:#{account.id}").count).to eq(1)
    expect(Agentkit::Exploration.store.find(world.id,
      scope: Agentkit::Scope.new(tenant_key: "account:#{account.id}", account_id: account.id))).not_to be_nil
    expect(Agentkit::Exploration.store.find(world.id,
      scope: Agentkit::Scope.new(tenant_key: "account:#{other.id}", account_id: other.id))).to be_nil
  end

  it "has unique durable world ids and scoped indexes" do
    indexes = ActiveRecord::Base.connection.indexes(:agentkit_exploration_worlds)

    expect(indexes.find { |index| index.name == "index_agentkit_exploration_worlds_on_world_id" }.unique).to be(true)
    expect(indexes.map(&:name)).to include("idx_agentkit_exploration_worlds_scope",
                                          "idx_agentkit_exploration_worlds_policy")
  end
end
