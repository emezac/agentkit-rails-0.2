# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Graph snapshot persistence", :integration do
  GraphUser = Struct.new(:id) unless const_defined?(:GraphUser)

  it "persists normalized snapshots and traverses only inside the scoped tenant" do
    account = account!(name: "Graph A")
    tenant = "account:#{account.id}"
    ctx = Agentkit::Context.new(account: account, user: GraphUser.new(7), tenant_key: tenant)
    snapshot = Agentkit.with_context(ctx) do
      asset = Agentkit::TeamMemory.create_asset(asset_type: "wiki", name: "PersistedWiki",
                                                 visibility: "private", owner_id: 7)
      Agentkit::TeamMemory::Wiki.add_page(asset, title: "Entry", content: "See [[Policy]]")
      Agentkit::TeamMemory::Wiki.add_page(asset, title: "Policy", content: "Validated")
      Agentkit::TeamMemory::Wiki.build_snapshot(asset)
    end

    expect(Agentkit::GraphSnapshotRecord.where(tenant_key: tenant).count).to eq(1)
    expect(Agentkit::GraphNodeRecord.where(tenant_key: tenant).count).to eq(2)
    expect(Agentkit::GraphEdgeRecord.where(tenant_key: tenant).count).to eq(1)
    visible = Agentkit::TeamMemory::Graph.visible(snapshot, context: ctx)
    expect(visible.node_count).to eq(2)

    other = Agentkit::Context.new(account: account!(name: "Graph B"), user: GraphUser.new(7))
    expect do
      Agentkit::TeamMemory::Graph.visible(snapshot, context: other)
    end.to raise_error(Agentkit::ConfigurationError, /another tenant/)
  end

  it "enforces unique snapshot and node identities in PostgreSQL" do
    indexes = ActiveRecord::Base.connection.indexes(:agentkit_graph_snapshots)
    node_indexes = ActiveRecord::Base.connection.indexes(:agentkit_graph_nodes)

    expect(indexes.find { |index| index.name == "index_agentkit_graph_snapshots_on_snapshot_id" }.unique).to be(true)
    expect(indexes.find { |index| index.name == "idx_agentkit_graph_snapshots_digest" }.unique).to be(true)
    expect(node_indexes.find { |index| index.name == "idx_agentkit_graph_nodes_identity" }.unique).to be(true)
  end
end
