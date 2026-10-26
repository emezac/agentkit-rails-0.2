# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Verified knowledge backends" do
  let(:k) { Agentkit::Knowledge }
  let(:at) { "2026-01-01T00:00:00Z" }
  let(:ontology) { k::Ontology.new(name: "Paths", version: "1", entities: ["Node"], relations: { "Edge" => %w[Node Node], "Reach" => %w[Node Node] }) }
  let(:rules) do
    x, y, z = %w[x y z].map { |v| k.var(v) }
    [k::Rule.new(id: "copy", version: "1", approved_by: "human", approved_at: at,
      head: atom("Reach", x, y), body: [atom("Edge", x, y)]),
     k::Rule.new(id: "transitive", version: "1", approved_by: "human", approved_at: at,
      head: atom("Reach", x, z), body: [atom("Reach", x, y), atom("Edge", y, z)])]
  end

  def atom(relation, *terms) = k::Atom.new(relation: relation, terms: terms)

  def snapshot(edges = [%w[a b], %w[b c]])
    facts = edges.each_with_index.map do |values, i|
      k::Assertion.new(id: "edge#{i}", scope: "tenant", relation: "Edge", values: values, source: "edges", source_version: "1", observed_at: at, valid_from: at)
    end
    k::Snapshot.new(ontology: ontology, scope: "tenant", at: at, facts: facts, rules: rules)
  end

  def verified(backend, **options)
    k::Backends::Verified.new(backend: backend, name: "test_adapter", version: "1", **options)
  end

  def adapter(&block)
    Object.new.tap { |object| object.define_singleton_method(:run, &block) }
  end

  def result(s, nodes:, complete: true)
    k::Result.new(snapshot: s, nodes: nodes, complete: complete, reason: nil, iterations: 1, steps: 0, limits: {})
  end

  it "matches reference closure on generated graphs and checks every witness" do
    random = Random.new(1110)
    tensor = k::Backends::BooleanTensor.new
    20.times do
      edges = %w[a b c d e].product(%w[a b c d e]).select { random.rand < 0.2 }
      s = snapshot(edges)
      reference = k::Engine.new.run(s)
      actual = verified(tensor).run(s)
      expect(actual).to be_complete
      expect(actual.data["nodes"].keys.sort).to eq(reference.data["nodes"].keys.sort)
      actual.data["nodes"].each do |key, node|
        expect(k::ProofChecker.new.verify(snapshot: s, relation: node["relation"], values: node["values"], proof: actual.proof(key))).to eq(true)
      end
    end
  end

  it "preserves union and the shared-variable join instead of Cartesian projection" do
    actual = verified(k::Backends::BooleanTensor.new).run(snapshot([%w[a b], %w[b c], %w[d e]]))
    expect(actual.query("Reach", "a", "c")["status"]).to eq("entailed")
    expect(actual.query("Reach", "a", "e")["status"]).to eq("not_entailed")
    expect(actual.query("Reach", "d", "e")["status"]).to eq("entailed")
  end

  it "retains partial sound proofs but never converts a limit into completeness" do
    actual = verified(k::Backends::BooleanTensor.new(max_steps: 1)).run(snapshot)
    expect(actual).not_to be_complete
    expect(actual.query("Reach", "a", "c")["status"]).to eq("incomplete")
    expect(actual.query("Edge", "a", "b")["status"]).to eq("entailed")
    expect(actual.data["reason"]).to eq("max_steps")
  end

  it "rejects unsupported grammar and bounds or performs explicit audited fallback" do
    limited = k::Backends::BooleanTensor.new(max_domain: 1)
    expect { verified(limited).run(snapshot) }.to raise_error(k::Backends::Failure)
    actual = verified(limited, fallback: "ruby").run(snapshot)
    expect(actual.data["backend"]["execution"]).to eq("ruby_fallback")
    expect(actual.data["backend"]["failure_class"]).to eq("Agentkit::Knowledge::Backends::Unsupported")
    expect(actual.query("Reach", "a", "c")["status"]).to eq("entailed")
    unary = k::Snapshot.new(ontology: k::Ontology.new(name: "Unary", version: "1", relations: { "P" => ["string"] }),
      scope: "tenant", at: at, facts: [], rules: [])
    expect { k::Backends::BooleanTensor.new.run(unary) }.to raise_error(k::Backends::Unsupported)
  end

  it "rejects invented facts, foreign snapshots and false completeness" do
    s = snapshot
    valid = k::Engine.new.run(s)
    corrupt = JSON.parse(JSON.generate(valid.data["nodes"]))
    corrupt.values.first["witness"]["assertion_digest"] = "forged"
    forged = result(s, nodes: corrupt)
    expect { verified(adapter { |_snapshot| forged }).run(s) }.to raise_error(k::Backends::Failure)
    empty = result(s, nodes: {})
    expect { verified(adapter { |_snapshot| empty }).run(s) }.to raise_error(k::Backends::Failure)
    foreign = k::Engine.new.run(snapshot([%w[d e]]))
    expect { verified(adapter { |_snapshot| foreign }).run(s) }.to raise_error(k::Backends::Failure)
  end

  it "does not certify completeness beyond reference or proof-checking budgets" do
    s = snapshot
    valid = k::Engine.new.run(s)
    runner = adapter { |_snapshot| valid }
    expect { verified(runner, max_steps: 1).run(s) }.to raise_error(k::Backends::Failure)
    expect { verified(runner, max_proof_nodes: 1).run(s) }.to raise_error(k::Backends::Failure)
    fallback = verified(runner, max_steps: 1, fallback: "ruby").run(s)
    expect(fallback).not_to be_complete
  end

  it "does not swallow adapter errors without explicit fallback" do
    broken = adapter { |_snapshot| raise "offline" }
    expect { verified(broken).run(snapshot) }.to raise_error(k::Backends::Failure)
    actual = verified(broken, fallback: "ruby").run(snapshot)
    expect(actual.data["backend"]["failure_class"]).to eq("RuntimeError")
  end

  it "keeps adapters reusable without state leaking between snapshots" do
    tensor = k::Backends::BooleanTensor.new
    expect(tensor.run(snapshot).query("Reach", "a", "c")["status"]).to eq("entailed")
    expect(tensor.run(snapshot([])).query("Reach", "a", "c")["status"]).to eq("not_entailed")
  end
end
