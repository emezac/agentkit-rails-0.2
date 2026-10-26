# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Verified finite abstractions" do
  let(:k) { Agentkit::Knowledge }

  def chain(name, elements)
    k::FiniteOrder.new(name: name, version: "1", elements: elements,
      leq: elements.each_with_index.flat_map { |a, i| elements.drop(i).map { |b| [a, b] } })
  end

  let(:concrete) { chain("Amount", %w[zero small large]) }
  let(:abstract) { chain("Band", %w[low high]) }
  let(:connection) do
    k::GaloisConnection.new(name: "Bands", version: "1", concrete: concrete, abstract: abstract,
      alpha: { zero: "low", small: "low", large: "high" }, gamma: { low: "small", high: "large" })
  end

  it "checks the full adjunction, closure extensivity and idempotence" do
    expect(connection.data["checked_pairs"]).to eq(6)
    concrete.elements.each do |c|
      closure = connection.concretize(connection.abstract_element(c))
      expect(concrete.below?(c, closure)).to eq(true)
      expect(connection.concretize(connection.abstract_element(closure))).to eq(closure)
      abstract.elements.each do |a|
        expect(abstract.below?(connection.abstract_element(c), a)).to eq(concrete.below?(c, connection.concretize(a)))
      end
    end
  end

  it "rejects false adjunctions, partial maps and invalid orders" do
    expect { k::GaloisConnection.new(name: "Bad", version: "1", concrete: concrete, abstract: abstract,
      alpha: { zero: "low", small: "low", large: "high" }, gamma: { low: "zero", high: "large" }) }.to raise_error(k::InvalidContract)
    expect { k::GaloisConnection.new(name: "Bad", version: "1", concrete: concrete, abstract: abstract, alpha: {}, gamma: {}) }.to raise_error(k::InvalidContract)
    expect { k::FiniteOrder.new(name: "Bad", version: "1", elements: %w[a b], leq: [["a", "b"]]) }.to raise_error(k::InvalidContract)
    expect { k::FiniteOrder.new(name: "Bad", version: "1", elements: %w[a b], leq: [%w[a a], %w[b b], %w[a b], %w[b a]]) }.to raise_error(k::InvalidContract)
    expect { k::FiniteOrder.new(name: "Bad", version: "1", elements: %w[a b c], leq: [%w[a a], %w[b b], %w[c c], %w[a b], %w[b c]]) }.to raise_error(k::InvalidContract)
  end

  it "composes verified layers and refuses mismatched middle domains" do
    top = chain("All", ["all"])
    next_layer = k::GaloisConnection.new(name: "Top", version: "1", concrete: abstract, abstract: top,
      alpha: { low: "all", high: "all" }, gamma: { all: "high" })
    composed = connection.compose(next_layer, name: "Tower", version: "1")
    expect(composed.abstract_element("zero")).to eq("all")
    expect(composed.concretize("all")).to eq("large")
    expect { connection.compose(connection, name: "Bad", version: "1") }.to raise_error(k::InvalidContract)
  end

  it "rechecks imported certificates rather than trusting flags or counts" do
    expect(k::GaloisConnection.from_json(JSON.generate(connection.to_h)).digest).to eq(connection.digest)
    tampered = JSON.parse(JSON.generate(connection.to_h))
    tampered["gamma"]["low"] = "zero"
    expect { k::GaloisConnection.from_json(JSON.generate(tampered)) }.to raise_error(k::InvalidContract)
    expect { k::GaloisConnection.from_json(JSON.generate(connection.to_h.merge("checked_pairs" => 0))) }.to raise_error(k::InvalidContract)
  end

  it "checks monotonicity and soundness of declared finite transformers" do
    concrete_map = { zero: "small", small: "large", large: "large" }
    transformer = k::AbstractTransformer.new(connection: connection, concrete_map: concrete_map,
      abstract_map: { low: "high", high: "high" })
    expect(transformer.data["checked_elements"]).to eq(3)
    expect(transformer.data["authorizes"]).to eq(false)
    expect { k::AbstractTransformer.new(connection: connection, concrete_map: concrete_map,
      abstract_map: { low: "low", high: "high" }) }.to raise_error(k::InvalidContract)
    expect { k::AbstractTransformer.new(connection: connection, concrete_map: { zero: "large", small: "zero", large: "large" },
      abstract_map: { low: "high", high: "high" }) }.to raise_error(k::InvalidContract)
  end

  def snapshot
    ontology = k::Ontology.new(name: "Values", version: "1", relations: { "Value" => ["integer"] })
    fact = k::Assertion.new(id: "value", scope: "tenant", relation: "Value", values: [1], source: "row", source_version: "1",
      observed_at: "2026-01-01T00:00:00Z", valid_from: "2026-01-01T00:00:00Z")
    k::Snapshot.new(ontology: ontology, scope: "tenant", at: "2026-01-01T00:00:00Z", facts: [fact], rules: [])
  end

  it "keeps concrete proofs in views without granting authority or proving absence" do
    s = snapshot
    view = k::AbstractionView.new(connection: connection, snapshot: s, result: k::Engine.new.run(s),
      claims: { zero: { relation: "Value", values: [0] }, small: { relation: "Value", values: [1] } })
    expect(view.query("low")["status"]).to eq("witnessed_abstraction")
    expect(view.query("high")["witnesses"].size).to eq(1)
    expect(view.query("low")["authorizes"]).to eq(false)
    expect(view.data["unresolved"][0]["status"]).to eq("unproven")
    expect { view.query("unknown") }.to raise_error(k::InvalidContract)
  end

  it "rejects forged concrete witnesses" do
    s = snapshot
    result = k::Engine.new.run(s)
    nodes = JSON.parse(JSON.generate(result.data["nodes"]))
    nodes.values.first["witness"]["assertion_digest"] = "forged"
    forged = k::Result.new(snapshot: s, nodes: nodes, complete: true, reason: nil, iterations: 1, steps: 0, limits: {})
    expect { k::AbstractionView.new(connection: connection, snapshot: s, result: forged,
      claims: { small: { relation: "Value", values: [1] } }) }.to raise_error(k::IntegrityError)
  end

  it "exports deterministic closed Lean obligations without executing user text" do
    artifact = k::LeanExport.new(connection: connection)
    expect(artifact.data["status"]).to eq("exported_not_lean_checked")
    expect(artifact.data["source"]).to include("by decide", "#print axioms adjunction")
    expect(artifact.data["source"]).not_to include("sorry", "native_decide", "small")
    expect(k::LeanExport.new(connection: connection).digest).to eq(artifact.digest)
  end

  it "bounds finite domains and serialized contracts" do
    expect { chain("TooMany", 65.times.map(&:to_s)) }.to raise_error(k::InvalidContract)
    expect { k::FiniteOrder.new(name: "x" * 1_048_576, version: "1", elements: ["a"], leq: [["a", "a"]]) }.to raise_error(k::InvalidContract)
  end

  if ENV["AGENTKIT_LEAN_BIN"]
    it "checks the exported obligation with the explicitly selected Lean toolchain" do
      require "tmpdir"
      require "open3"
      require "timeout"
      Dir.mktmpdir("agentkit-lean-") do |dir|
        path = File.join(dir, "Abstraction.lean")
        File.write(path, k::LeanExport.new(connection: connection).data.fetch("source"))
        output, error, status = Timeout.timeout(30) { Open3.capture3(ENV.fetch("AGENTKIT_LEAN_BIN"), path, chdir: dir) }
        expect(status.success?).to eq(true), "#{output}\n#{error}"
        expect(output).not_to include("sorryAx")
      end
    end
  end
end
