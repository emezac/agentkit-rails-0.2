# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "Agentkit 0.6 graph retrieval" do
  EvalUser = Struct.new(:id) unless const_defined?(:EvalUser)

  before do
    Agentkit.reset!
    Agentkit::Flow.test_mode!
  end

  def private_asset(type: "wiki", name: "Graph", tenant: "tenant:a")
    Agentkit::TeamMemory.create_asset(asset_type: type, name: name, visibility: "private",
                                      owner_id: 7, tenant_key: tenant)
  end

  def context(tenant: "tenant:a", principal: nil)
    Agentkit::Context.new(user: EvalUser.new(7), tenant_key: tenant, principal: principal)
  end

  it "builds canonical Wiki snapshots and keeps unresolved links as diagnostics" do
    asset = private_asset(name: "EngineeringWiki")
    Agentkit.with_context(context) do
      Agentkit::TeamMemory::Wiki.add_page(asset, title: "Café API", content: "See [[Refund Policy]] and [[Missing]]")
      Agentkit::TeamMemory::Wiki.add_page(asset, title: "Refund Policy", content: "See [[Café API]]")
    end

    first = Agentkit::TeamMemory::Wiki.build_snapshot(asset)
    second = Agentkit::TeamMemory::Wiki.build_snapshot(asset)

    expect(first.digest).to eq(second.digest)
    expect(first.snapshot_id).to eq(second.snapshot_id)
    expect(first.nodes.map(&:node_type)).to contain_exactly("page", "page")
    expect(first.edges.map(&:edge_type)).to contain_exactly("wikilink", "wikilink")
    expect(first.diagnostics["unresolved_links"].size).to eq(1)
    expect(first.diagnostics["cycles"]).not_to be_empty
  end

  it "applies ACL before traversal so hidden nodes and incident edges cannot affect scores" do
    asset = private_asset
    visibility = Agentkit::TeamMemory::Graph.visibility_digest(asset)
    visible = Agentkit::TeamMemory::Graph::Node.new(
      node_id: "visible", tenant_key: asset.tenant_key, asset_id: asset.id, node_type: :page,
      external_ref: "visible", visibility_digest: visibility, content_digest: "sha256:v"
    )
    hidden = Agentkit::TeamMemory::Graph::Node.new(
      node_id: "hidden", tenant_key: asset.tenant_key, asset_id: asset.id, node_type: :page,
      external_ref: "hidden", visibility_digest: visibility, content_digest: "sha256:h",
      metadata: { hidden: true }
    )
    edge = Agentkit::TeamMemory::Graph::Edge.new(
      edge_id: "edge", from_node_id: "visible", to_node_id: "hidden", edge_type: :wikilink,
      source_digest: "sha256:e"
    )
    snapshot = Agentkit::TeamMemory::Graph.build(asset: asset, nodes: [visible, hidden], edges: [edge])

    authorized = Agentkit::TeamMemory::Graph.visible(snapshot, context: context)
    result = Agentkit::TeamMemory::SpreadingActivation.retrieve(
      "visible", graph: snapshot, seeds: [{ id: "visible", score: 1 }], context: context
    )

    expect(authorized.nodes.map(&:node_id)).to eq(["visible"])
    expect(authorized.edges).to be_empty
    expect(result.visited_nodes).to eq(1)
    expect(result.ranked.map { |row| row["external_ref"] }).to eq(["visible"])
    expect(result.trace.to_h.to_s).not_to include("hidden")
  end

  it "handles cycles, dangling mass and direction with bounded PPR" do
    asset = private_asset
    visibility = Agentkit::TeamMemory::Graph.visibility_digest(asset)
    nodes = %w[a b c dangling].map do |id|
      Agentkit::TeamMemory::Graph::Node.new(
        node_id: id, tenant_key: asset.tenant_key, asset_id: asset.id, node_type: :page,
        external_ref: id, visibility_digest: visibility, content_digest: "sha256:#{id}"
      )
    end
    edges = [%w[a b], %w[b c], %w[c a]].map.with_index do |(from, to), index|
      Agentkit::TeamMemory::Graph::Edge.new(edge_id: "e#{index}", from_node_id: from,
                                            to_node_id: to, edge_type: :wikilink,
                                            source_digest: "sha256:e#{index}")
    end
    snapshot = Agentkit::TeamMemory::Graph.build(asset: asset, nodes: nodes, edges: edges)
    outbound = Agentkit::TeamMemory::SpreadingActivation.retrieve(
      "a", graph: snapshot, seeds: [{ id: "a", score: 1 }], direction: :outbound, context: context
    )
    inbound = Agentkit::TeamMemory::SpreadingActivation.retrieve(
      "a", graph: snapshot, seeds: [{ id: "a", score: 1 }], direction: :inbound, context: context
    )

    expect(outbound.iterations).to be <= Agentkit.config.team_memory.graph_max_iterations
    expect(outbound.ranked.map { |row| row["external_ref"] }).to include("b")
    expect(inbound.ranked.map { |row| row["external_ref"] }).to include("c")
    expect(outbound.ranked.sum { |row| row["graph_score"] }).to be_within(1e-6).of(1.0)

    dangling = Agentkit::TeamMemory::SpreadingActivation.retrieve(
      "dangling", graph: snapshot, seeds: [{ id: "dangling", score: 1 }], context: context
    )
    expect(dangling).to be_converged
    expect(dangling.ranked.first["graph_score"]).to eq(1.0)
  end

  it "degrades deterministically and can fail closed when graph is required" do
    optional = Agentkit::TeamMemory::SpreadingActivation.retrieve(
      "query", graph: "missing", seeds: [], context: context
    )
    expect(optional.degraded_reason).to eq("graph_missing")
    expect do
      Agentkit::TeamMemory::SpreadingActivation.retrieve(
        "query", graph: "missing", seeds: [], context: context, required: true
      )
    end.to raise_error(Agentkit::ConfigurationError, /required/)
  end

  it "refuses cross-tenant graph traversal" do
    asset = private_asset
    visibility = Agentkit::TeamMemory::Graph.visibility_digest(asset)
    node = Agentkit::TeamMemory::Graph::Node.new(
      node_id: "a", tenant_key: asset.tenant_key, asset_id: asset.id, node_type: :page,
      external_ref: "a", visibility_digest: visibility, content_digest: "sha256:a"
    )
    snapshot = Agentkit::TeamMemory::Graph.build(asset: asset, nodes: [node], edges: [])

    expect do
      Agentkit::TeamMemory::Graph.visible(snapshot, context: context(tenant: "tenant:b"))
    end.to raise_error(Agentkit::ConfigurationError, /another tenant/)
  end

  it "uses Ripper AST qualified identifiers and blocks symlinks/out-of-root files" do
    Dir.mktmpdir do |dir|
      allowed = File.join(dir, "allowed")
      Dir.mkdir(allowed)
      source = File.join(allowed, "service.rb")
      File.write(source, "module Billing\n class Base; end\n class Charge < Base\n  def call\n   persist\n  end\n  def persist; end\n end\nend\n")
      link = File.join(allowed, "link.rb")
      File.symlink(source, link)
      outside = File.join(dir, "outside.rb")
      File.write(outside, "class Outside; end")
      asset = private_asset(type: "code_graph", name: "Code")

      entries = Agentkit::TeamMemory::CodeGraph.index_files(asset, [source], allowed_roots: [allowed])
      snapshot = Agentkit::TeamMemory::CodeGraph.build_snapshot(asset)
      repeated_entries = Agentkit::TeamMemory::CodeGraph.index_files(asset, [source], allowed_roots: [allowed])
      repeated_snapshot = Agentkit::TeamMemory::CodeGraph.build_snapshot(asset)

      expect(entries.map(&:qualified_name)).to include("Billing", "Billing::Charge", "Billing::Charge#call")
      expect(snapshot.edges.map(&:edge_type)).to include("contains", "calls", "inherits")
      expect(snapshot.diagnostics["metaprogramming_complete"]).to be(false)
      expect(repeated_entries.size).to eq(entries.size)
      expect(repeated_snapshot.snapshot_id).to eq(snapshot.snapshot_id)
      expect do
        Agentkit::TeamMemory::CodeGraph.index_files(asset, [link], allowed_roots: [allowed])
      end.to raise_error(Agentkit::ConfigurationError, /symlink/)
      expect do
        Agentkit::TeamMemory::CodeGraph.index_files(asset, [outside], allowed_roots: [allowed])
      end.to raise_error(Agentkit::ConfigurationError, /outside allowed roots/)
    end
  end

  it "enforces server-side graph size limits before solving" do
    asset = private_asset
    visibility = Agentkit::TeamMemory::Graph.visibility_digest(asset)
    nodes = %w[a b].map do |id|
      Agentkit::TeamMemory::Graph::Node.new(
        node_id: id, tenant_key: asset.tenant_key, asset_id: asset.id, node_type: :page,
        external_ref: id, visibility_digest: visibility, content_digest: "sha256:#{id}"
      )
    end
    snapshot = Agentkit::TeamMemory::Graph.build(asset: asset, nodes: nodes, edges: [])
    Agentkit.config.team_memory.graph_max_nodes = 1

    result = Agentkit::TeamMemory::SpreadingActivation.retrieve(
      "a", graph: snapshot, seeds: [{ id: "a" }], context: context
    )
    expect(result.degraded_reason).to eq("graph_too_large")
  end

  it "rejects unvalidated LLM-inferred edges from active snapshots" do
    asset = private_asset
    visibility = Agentkit::TeamMemory::Graph.visibility_digest(asset)
    nodes = %w[a b].map do |id|
      Agentkit::TeamMemory::Graph::Node.new(
        node_id: id, tenant_key: asset.tenant_key, asset_id: asset.id, node_type: :page,
        external_ref: id, visibility_digest: visibility, content_digest: "sha256:#{id}"
      )
    end
    edge = Agentkit::TeamMemory::Graph::Edge.new(
      edge_id: "llm", from_node_id: "a", to_node_id: "b", edge_type: :references,
      source_digest: "sha256:prompt", confidence: 0.7, metadata: { provenance: "llm_inference" }
    )

    expect do
      Agentkit::TeamMemory::Graph.build(asset: asset, nodes: nodes, edges: [edge])
    end.to raise_error(Agentkit::ConfigurationError, /unvalidated LLM/)
  end


  it "computes reproducible retrieval metrics without inferring hidden nodes" do
    dataset = Agentkit::TeamMemory::Evaluation.sample_dataset_path
    report = Agentkit::TeamMemory::Evaluation.run(dataset)

    expect(report[:dataset_digest]).to start_with("sha256:")
    expect(report[:query_count]).to eq(4)
    expect(report[:strategies].keys).to contain_exactly("keyword", "hybrid_graph")
    expect(report[:strategies]["hybrid_graph"][:hidden_inferences]).to eq(0)
    expect(report[:strategies]["hybrid_graph"][:latency_p95_ms]).to be >= 0
  end


  it "publishes traces only to the same tenant and principal" do
    asset = private_asset
    visibility = Agentkit::TeamMemory::Graph.visibility_digest(asset)
    node = Agentkit::TeamMemory::Graph::Node.new(
      node_id: "a", tenant_key: asset.tenant_key, asset_id: asset.id, node_type: :page,
      external_ref: "a", visibility_digest: visibility, content_digest: "sha256:a"
    )
    snapshot = Agentkit::TeamMemory::Graph.build(asset: asset, nodes: [node], edges: [])
    result = Agentkit::TeamMemory::SpreadingActivation.retrieve(
      "raw private query", graph: snapshot, seeds: [{ id: "a" }], context: context
    )
    id = Agentkit::TeamMemory::Visualization.publish(result.trace, context: context)

    expect(Agentkit::TeamMemory::Visualization.fetch(id, context: context)).to equal(result.trace)
    expect(Agentkit::TeamMemory::Visualization.fetch(id, context: context(principal: "other"))).to be_nil
    expect(result.trace.to_h.to_s).not_to include("raw private query")
  end
end
