# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentkit::Knowledge do
  K = Agentkit::Knowledge
  let(:at) { "2026-10-25T12:00:00Z" }
  let(:ontology) do
    K::Ontology.new(name: "Graph", version: "1", entities: ["Person"],
                    relations: { "Edge" => %w[Person Person], "Reach" => %w[Person Person],
                                 "Other" => %w[Person Person] })
  end

  def atom(name, *terms) = K::Atom.new(relation: name, terms: terms)
  def variable(name) = K.var(name)
  def fact(id, relation, *values, **overrides)
    K::Assertion.new(**{ id: id, scope: "shop:1", relation: relation, values: values,
                        source: "record:#{id}", source_version: "1", observed_at: at,
                        valid_from: at }.merge(overrides))
  end
  def rule(id, head, *body, **overrides)
    K::Rule.new(**{ id: id, version: "1", head: head, body: body,
                   approved_by: "operator:1", approved_at: at }.merge(overrides))
  end
  def snapshot(facts: [], rules: [], **overrides)
    K::Snapshot.new(**{ ontology: ontology, scope: "shop:1", at: at, facts: facts, rules: rules }.merge(overrides))
  end
  def closure_rules
    x, y, z = %w[x y z].map { |name| variable(name) }
    [rule("base", atom("Reach", x, y), atom("Edge", x, y)),
     rule("recursive", atom("Reach", x, z), atom("Reach", x, y), atom("Edge", y, z))]
  end

  it "joins on body variables before projecting the head (legacy regression)" do
    x, y, z = %w[x y z].map { |name| variable(name) }
    s = snapshot(facts: [fact("1", "Edge", "alice", "bob"), fact("2", "Other", "bob", "carol")],
                 rules: [rule("join", atom("Reach", x, z), atom("Edge", x, y), atom("Other", y, z))])
    result = K::Engine.new.run(s)
    expect(result.query("Reach", "alice", "carol")["status"]).to eq("entailed")
    expect(result.query("Reach", "carol", "alice")["status"]).to eq("not_entailed")
  end

  it "unions multiple clauses, preserves observations and reaches a fixpoint" do
    x, y = %w[x y].map { |name| variable(name) }
    s = snapshot(facts: [fact("1", "Edge", "a", "b"), fact("2", "Other", "c", "d"), fact("3", "Reach", "e", "f")],
                 rules: [rule("one", atom("Reach", x, y), atom("Edge", x, y)),
                         rule("two", atom("Reach", x, y), atom("Other", x, y))])
    result = K::Engine.new.run(s)
    expect(result).to be_complete
    [%w[a b], %w[c d], %w[e f]].each { |pair| expect(result.query("Reach", *pair)["status"]).to eq("entailed") }
  end

  it "matches an independent graph traversal reference on generated cyclic graphs" do
    random = Random.new(170)
    20.times do
      vertices = %w[a b c d e]
      edges = vertices.product(vertices).select { random.rand < 0.28 }
      s = snapshot(facts: edges.each_with_index.map { |pair, index| fact(index.to_s, "Edge", *pair) }, rules: closure_rules)
      result = K::Engine.new.run(s)
      expect(result).to be_complete
      vertices.each do |start|
        reached, queue = [], edges.select { |a, _| a == start }.map(&:last)
        until queue.empty?
          node = queue.shift
          next if reached.include?(node)
          reached << node
          queue.concat(edges.select { |a, _| a == node }.map(&:last))
        end
        vertices.each do |finish|
          query = result.query("Reach", start, finish)
          expect(query["status"]).to eq(reached.include?(finish) ? "entailed" : "not_entailed")
          if reached.include?(finish)
            expect(K::ProofChecker.new.verify(snapshot: s, relation: "Reach", values: [start, finish], proof: query["proof"])).to be(true)
          end
        end
      end
    end
  end

  it "handles constants, repeated variables and reordered heads" do
    x, y = %w[x y].map { |name| variable(name) }
    rules = [rule("reverse", atom("Reach", y, x), atom("Edge", x, y)),
             rule("equal", atom("Other", x, "marker"), atom("Edge", x, x))]
    result = K::Engine.new.run(snapshot(facts: [fact("1", "Edge", "a", "b"), fact("2", "Edge", "c", "c")], rules: rules))
    expect(result.query("Reach", "b", "a")["status"]).to eq("entailed")
    expect(result.query("Other", "c", "marker")["status"]).to eq("entailed")
    expect(result.query("Other", "a", "marker")["status"]).to eq("not_entailed")
  end

  it "reports incomplete on iteration, join-work and tuple limits" do
    s = snapshot(facts: [fact("1", "Edge", "a", "b"), fact("2", "Edge", "b", "c")], rules: closure_rules)
    [{ max_iterations: 1 }, { max_steps: 1 }, { max_facts: 1 }].each do |limit|
      result = K::Engine.new(**limit).run(s)
      expect(result).not_to be_complete
      expect(result.data["reason"]).to eq(limit.keys.first.to_s)
      expect(result.query("Reach", "z", "z")["status"]).to eq("incomplete")
      expect(result.query("Edge", "a", "b")["status"]).to eq("entailed")
    end
  end

  it "distinguishes absence from explicit false and preserves false bindings" do
    typed = K::Ontology.new(name: "Typed", version: "1", relations: { "Input" => ["boolean"], "Output" => ["boolean"] })
    x = variable("x")
    s = snapshot(ontology: typed, facts: [fact("1", "Input", false)], rules: [rule("copy", atom("Output", x), atom("Input", x))])
    result = K::Engine.new.run(s)
    expect(result.query("Output", false)["status"]).to eq("entailed")
    expect(result.query("Output", true)["status"]).to eq("not_entailed")
  end

  it "freezes caller data and is deterministic across input permutations" do
    values = [+"a", +"b"]
    f = fact("1", "Edge", *values)
    s = snapshot(facts: [f, fact("2", "Edge", "b", "c")], rules: closure_rules)
    values.first.replace("mutated")
    other = snapshot(facts: s.facts.reverse, rules: s.rules.reverse)
    expect(other.digest).to eq(s.digest)
    expect(K::Engine.new.run(other).digest).to eq(K::Engine.new.run(s).digest)
    expect { s.data["facts"] << {} }.to raise_error(FrozenError)
  end

  it "selects evidence as of the snapshot with half-open validity intervals" do
    s = snapshot(facts: [fact("valid", "Edge", "a", "b"),
                         fact("expired", "Edge", "b", "c", valid_from: "2026-10-24T12:00:00Z", valid_until: at),
                         fact("future", "Edge", "c", "d", observed_at: "2026-10-26T12:00:00Z")], rules: closure_rules)
    result = K::Engine.new.run(s)
    expect(result.query("Reach", "a", "b")["status"]).to eq("entailed")
    expect(result.query("Reach", "a", "c")["status"]).to eq("not_entailed")
    expect(s.facts.size).to eq(3)
  end

  it "retracts by rebuilding snapshots without changing historical results" do
    engine = K::Engine.new
    old = engine.run(snapshot(facts: [fact("1", "Edge", "a", "b")], rules: closure_rules))
    new_result = engine.run(snapshot(rules: closure_rules))
    expect(old.query("Reach", "a", "b")["status"]).to eq("entailed")
    expect(new_result.query("Reach", "a", "b")["status"]).to eq("not_entailed")
    expect(new_result.data["snapshot_digest"]).not_to eq(old.data["snapshot_digest"])
  end

  it "rejects hypotheses, cross-tenant facts and duplicate identifiers" do
    expect { snapshot(facts: [fact("1", "Edge", "a", "b", kind: "hypothesis")]) }.to raise_error(K::InvalidContract, /hypotheses/)
    expect { snapshot(facts: [fact("1", "Edge", "a", "b", scope: "shop:2")]) }.to raise_error(K::InvalidContract, /scope/)
    expect { snapshot(facts: [fact("1", "Edge", "a", "b"), fact("1", "Edge", "b", "c")]) }.to raise_error(K::InvalidContract, /duplicate/)
  end

  it "rejects unknown relations, wrong arity, wrong types and nominal domain crossings" do
    expect { snapshot(facts: [fact("1", "Missing", "a")]) }.to raise_error(K::InvalidContract)
    expect { snapshot(facts: [fact("1", "Edge", "a")]) }.to raise_error(K::InvalidContract)
    expect { snapshot(facts: [fact("1", "Edge", 42, "b")]) }.to raise_error(K::InvalidContract)
    typed = K::Ontology.new(name: "Shop", version: "1", entities: %w[Order Customer], relations: { "Order" => ["Order"], "Customer" => ["Customer"] })
    x = variable("x")
    expect { snapshot(ontology: typed, rules: [rule("bad", atom("Order", x), atom("Customer", x))]) }.to raise_error(K::InvalidContract, /nominal/)
  end

  it "rejects unsafe, unapproved and future-approved rules" do
    expect { rule("unsafe", atom("Reach", variable("x"), variable("z")), atom("Edge", variable("x"), variable("y"))) }.to raise_error(K::InvalidContract, /head variables/)
    expect { rule("empty", atom("Edge", "a", "b"), approved_by: "") }.to raise_error(K::InvalidContract)
    future = rule("future", atom("Reach", variable("x"), variable("y")), atom("Edge", variable("x"), variable("y")), approved_at: "2026-10-26T12:00:00Z")
    expect { snapshot(rules: [future]) }.to raise_error(K::InvalidContract, /approved/)
  end

  it "rejects timestamps without timezone, empty intervals and invalid limits" do
    expect { fact("1", "Edge", "a", "b", observed_at: "2026-10-25T12:00:00") }.to raise_error(K::InvalidContract)
    expect { fact("1", "Edge", "a", "b", valid_until: at) }.to raise_error(K::InvalidContract)
    expect { K::Engine.new(max_steps: 0) }.to raise_error(K::InvalidContract)
    expect { K::Engine.new(unknown: 1) }.to raise_error(K::InvalidContract)
  end

  it "verifies detached JSON proofs and rejects modified evidence, bindings and rules" do
    s = snapshot(facts: [fact("1", "Edge", "a", "b"), fact("2", "Edge", "b", "c")], rules: closure_rules)
    proof = K::Engine.new.run(s).query("Reach", "a", "c").fetch("proof")
    check = ->(candidate, source = s) { K::ProofChecker.new.verify(snapshot: source, relation: "Reach", values: %w[a c], proof: candidate) }
    expect(check.call(JSON.parse(JSON.generate(proof)))).to be(true)
    %w[rule_digest bindings premises].each do |field|
      changed = JSON.parse(JSON.generate(proof))
      changed["nodes"][changed["root"]]["witness"][field] = "tampered"
      expect(check.call(changed)).to be(false)
    end
    expect(check.call(proof, snapshot(rules: closure_rules))).to be(false)
    expect(check.call({})).to be(false)
    changed = JSON.parse(JSON.generate(proof))
    changed["nodes"][changed["root"]]["witness"]["premises"] = [changed["root"]]
    expect(check.call(changed)).to be(false)
  end

  it "binds proofs to approval versions and source versions" do
    f = fact("1", "Edge", "a", "b")
    s = snapshot(facts: [f], rules: closure_rules)
    proof = K::Engine.new.run(s).query("Reach", "a", "b")["proof"]
    changed = snapshot(facts: [fact("1", "Edge", "a", "b", source_version: "2")], rules: closure_rules)
    expect(K::ProofChecker.new.verify(snapshot: changed, relation: "Reach", values: %w[a b], proof: proof)).to be(false)
  end

  it "round trips snapshots and replays with identical content digests" do
    s = snapshot(facts: [fact("1", "Edge", "a", "b")], rules: closure_rules)
    restored = K::Snapshot.from_json(JSON.generate(s.to_h))
    expect(restored.digest).to eq(s.digest)
    expect(K::Engine.new.run(restored).digest).to eq(K::Engine.new.run(s).digest)
  end

  it "rejects corrupt, extended and oversized imported contracts" do
    payload = JSON.parse(JSON.generate(snapshot.to_h))
    payload["schema_version"] = 2
    expect { K::Snapshot.from_json(JSON.generate(payload)) }.to raise_error(K::InvalidContract)
    payload["schema_version"] = 1
    payload["eval"] = "arbitrary code"
    expect { K::Snapshot.from_json(JSON.generate(payload)) }.to raise_error(K::InvalidContract)
    expect { K::Snapshot.from_json("not json") }.to raise_error(K::InvalidContract)
    expect { K::Snapshot.from_json(" " * (K::Snapshot::MAX_BYTES + 1)) }.to raise_error(K::InvalidContract)
    expect { K::Snapshot.from_json("[]") }.to raise_error(K::InvalidContract)
  end

  it "rejects a forged rule version, extra evidence and cyclic derivations" do
    x, y = %w[x y].map { |name| variable(name) }
    self_rule = rule("self", atom("Reach", x, y), atom("Reach", x, y))
    s = snapshot(facts: [fact("1", "Edge", "a", "b")], rules: closure_rules + [self_rule])
    proof = K::Engine.new.run(s).query("Reach", "a", "b")["proof"]
    check = ->(candidate) { K::ProofChecker.new.verify(snapshot: s, relation: "Reach", values: %w[a b], proof: candidate) }
    changed = JSON.parse(JSON.generate(proof))
    changed["nodes"]["extra"] = {}
    expect(check.call(changed)).to be(false)
    changed = JSON.parse(JSON.generate(proof))
    root = changed.fetch("root")
    changed["nodes"] = { root => { "relation" => "Reach", "values" => %w[a b], "witness" => {
      "kind" => "derived", "rule_id" => "self", "rule_digest" => self_rule.digest,
      "bindings" => { "x" => "a", "y" => "b" }, "premises" => [root]
    } } }
    expect(check.call(changed)).to be(false)
    revised = rule("base", atom("Reach", x, y), atom("Edge", x, y), version: "2")
    changed_snapshot = snapshot(facts: s.facts, rules: [revised])
    expect(K::ProofChecker.new.verify(snapshot: changed_snapshot, relation: "Reach", values: %w[a b], proof: proof)).to be(false)
  end

  it "bounds snapshot collections and rejects invalid query shapes" do
    f = fact("1", "Edge", "a", "b")
    expect { snapshot(facts: [f] * (K::Snapshot::MAX_FACTS + 1)) }.to raise_error(K::InvalidContract)
    result = K::Engine.new.run(snapshot)
    expect { result.query("Missing", "a") }.to raise_error(K::InvalidContract)
    expect { result.query("Edge", "a") }.to raise_error(K::InvalidContract)
    expect { atom("Edge", { "eval" => "code" }) }.to raise_error(K::InvalidContract)
  end

  it "runs the published returns example and verifies its review eligibility" do
    require_relative "../../examples/knowledge_returns"
    demo = KnowledgeReturnsExample.run
    expect(demo.fetch(:query).fetch("status")).to eq("entailed")
    expect(demo.fetch(:proof_verified)).to be(true)
    expect(demo.fetch(:result)).to be_complete
  end
end
