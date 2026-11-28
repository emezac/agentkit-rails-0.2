# Deterministic research evidence gate

`Harness::ResearchEvidence` is an opt-in, pure Ruby gate for **literal** source
excerpts. It addresses the omission seen in the [twelve-case live pilot](RESEARCH_LIVE_PILOT.md):
the model sometimes returned no citation despite an exact matching passage.
The gate checks bounded question needles against host-authorized, versioned
source content before any model synthesis. It makes no model or network call,
persists nothing, grants no permission and requires no migration.

```ruby
gate = Agentkit::Harness::ResearchEvidence.new(
  loader: ->(ref, context) {
    row = PolicyDocument.authorized_for(ref.fetch("id"), context)
    {
      id: row.id.to_s, reference: row.reference, version: row.version.to_s,
      kind: "primary", scope: Agentkit::Knowledge::Boundary.scope(context),
      content: row.body
    }
  },
  authorize: ->(action, ref, context) {
    ResearchPolicy.allowed?(action, ref, context)
  }
)

questions = [{ id: "refund_window", needle: "within 30 days" }]
sources = [{ id: "policy-42", reference: "policy/returns", version: "3",
  kind: "primary", digest: Agentkit::Knowledge.digest(policy_body) }]

report = gate.build(questions: questions, sources: sources, context: researcher_context)
review = gate.verify(report: report, questions: questions, sources: sources,
  context: independent_verifier_context)
```

The host supplies exactly one trusted descriptor per source: `id`,
`reference`, `version`, `kind` (`primary` or `secondary`) and a digest computed
with `Knowledge.digest(content)`. Its loader returns exactly those identity
fields, the current `content`, and the current
`Knowledge::Boundary.scope(context)`. The gate
checks the descriptor against the loaded bytes and scope before extracting
anything. `authorize` receives `build` or `verify`, the descriptor and the
execution context; it must explicitly approve the action. Give the verifier
a distinct principal and current source access.

Matching primary-source lines become exact quoted claims. No match becomes
`no_matching_primary_source`. Multiple distinct matching lines become
`conflicting_sources` with the source IDs for review. Secondary sources do
not create claims. The report has a source-snapshot digest and
`authorizes: false`. `verify` reloads all sources and recomputes the report;
tampering returns `evidence_mismatch`, while denied or changed source reads
raise and fail closed. Limits: 1..32 questions, 1..16 sources, 64 KiB per
source, and 4 KiB per matching quote.

This is substring matching, not semantic entailment. Distinct lines may be
compatible rather than contradictory; a human or domain verifier resolves
their meaning. A model may write prose from the checked claims, but that
prose is not verified by this API. Keep it separate from the authoritative
report and require another verifier for inferred or summarized statements.

Rails owns authenticated identities, tenant-scoped source relations, row
locking or immutable source archives, source freshness, the source manifest,
the two principals' permissions, and any persisted report or action. Use the
[runnable example](../examples/research_evidence_gates.rb) to see the twelve
synthetic cases, including missing answers and a source conflict. All twelve
pass the deterministic gate; that is a fixture check, not evidence about
real-world research quality.
