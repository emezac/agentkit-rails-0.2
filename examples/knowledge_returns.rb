# frozen_string_literal: true

# Run: ruby -Ilib examples/knowledge_returns.rb
# The timestamps and policy are fixtures, not a legal or operational policy.
require "agentkit"

module KnowledgeReturnsExample
  def self.run
    k = Agentkit::Knowledge
    at = "2026-10-25T12:00:00Z"
    ontology = k::Ontology.new(
      name: "Returns", version: "1", entities: ["Order"],
      relations: { "Paid" => ["Order"], "WithinWindow" => ["Order"],
                   "EligibleForReview" => ["Order"] }
    )
    order = k.var("order")
    rule = k::Rule.new(
      id: "return_review", version: "1",
      head: k::Atom.new(relation: "EligibleForReview", terms: [order]),
      body: [k::Atom.new(relation: "Paid", terms: [order]),
             k::Atom.new(relation: "WithinWindow", terms: [order])],
      approved_by: "policy-owner:demo", approved_at: at
    )
    facts = %w[Paid WithinWindow].map do |relation|
      k::Assertion.new(id: "order:42:#{relation}", scope: "shop:demo",
        relation: relation, values: ["order:42"], source: "orders/42",
        source_version: "lock:3/policy:1", observed_at: at, valid_from: at)
    end
    snapshot = k::Snapshot.new(ontology: ontology, scope: "shop:demo", at: at, facts: facts, rules: [rule])
    result = k::Engine.new.run(snapshot)
    query = result.query("EligibleForReview", "order:42")
    verified = k::ProofChecker.new.verify(snapshot: snapshot, relation: "EligibleForReview",
                                         values: ["order:42"], proof: query.fetch("proof"))
    { snapshot: snapshot, result: result, query: query, proof_verified: verified }
  end
end

if $PROGRAM_NAME == __FILE__
  result = KnowledgeReturnsExample.run
  puts JSON.pretty_generate(result.fetch(:query).merge("proof_verified" => result.fetch(:proof_verified)))
end
