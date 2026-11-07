# Evidence-Grounded Memory Consolidation — 1.13.0

Memory is a reviewed representation of evidence, not a replacement for operational
data. The library never turns model text into permissions, a causal proof, a
Knowledge rule, or an executable skill. The host owns the meaning of evidence.

## Responsibility boundary

| AgentKit | Host Rails application |
| --- | --- |
| Typed claims, exact quotes and content/version binding | Authoritative source adapters, original transcripts, domain meaning and complete context |
| Scoped immutable candidates and revisions | Authentication, tenant/account membership, document ACLs, human identities |
| Independent-actor check and verifier contract | Human publication policy and independently validated semantic verifier |
| Atomic revision expectations and preserved history | Which topic names represent the same knowledge, merge decisions and application rollout |
| TTL, dependency rechecks and explicit invalidation | Source change events, clocks, observation freshness, retention/redaction and maintenance scheduling |
| Bounded pointer index through ContextMap | Task-specific topic selection and explicit context injection |
| Offline paired comparison | Blind fixtures, isolated runners, truthful cost accounting, grading and acceptance thresholds |

A transcript proves what was recorded, not that its assertions were true. A quote
match proves the text occurs in the source, not that the proposed interpretation
follows from it. The host verifier receives full checked source content to examine
negations, exceptions, contradictions and scope. It must not merely ask the same
proposing model whether its own answer is correct. No model provider is required.

## Installation and wiring

Use migrations 024 (Journal) and 030 (scoped memory heads). Publication state and
Journal must share a database connection pool. No jobs, external readers, or public
HTTP endpoints are installed automatically.

```ruby
journal = Agentkit::Knowledge::Journal.new(
  authorize: ->(kind, ctx) { MemoryPolicy.journal?(ctx, kind) }
)
library = Agentkit::Memory::Consolidation.new(
  journal: journal,
  authorize: ->(action, ctx) { MemoryPolicy.allowed?(ctx, action) },
  loader: ->(source, ctx) { EvidenceReader.read_current(source, ctx) },
  verifier: ->(candidate, ctx) { MemoryVerifier.check(candidate, ctx) },
  verifier_version: "memory-review:1"
)
```

The three host classes above are integration points, not provided implementations.
Authorization actions are `propose`, `read`, `read_history`, `publish`, `invalidate`, `revoke`.
Deny unknown actions. `publish` requires an authenticated human with review rights;
the library additionally rejects the original creator as reviewer. `revoke` should
require a human safety role. Journal kind `memory` is authorized separately.
Never accept a tenant, reviewer identity or source classification from the LLM
without authoritative server-side validation. Every API requires a context with
principal and tenant/account scope. Shared service identities are not human proof.

`read_history` is a separate audit privilege for `candidate`, `head` and `revision`,
and is needed by reviewers during publication. It grants access to persisted
quotations in the caller's tenant/account without rereading original sources.
Restrict it to appropriate data custodians; do not grant it to ordinary retrieval
agents as a fallback when source ACLs deny access. For document-level audit ACLs,
enforce them in the host endpoint before permitting a history call.

## Source contract and candidate creation

The host registers source declarations, each with exactly:
`id`, `reference`, `version`, `digest`, `kind`, `max_age_seconds`.
Kinds are `record`, `tool_result`, `document`, `user_statement`, `model_output`.
Classifications are host-attested; an agent cannot turn its own output into a
`record` by naming it that way. Bind references to allowlisted scoped resources,
not arbitrary URLs/files chosen by the model.

The loader receives `(source, context)` and must return exactly:

```ruby
{
  scope: Agentkit::Knowledge::Boundary.scope(ctx),
  reference: "policies/returns", version: "2026-11-06.1", kind: "document",
  content: "Returns require an invoice. No automatic refunds.",
  observed_at: Time.now.utc.iso8601(6)
}
```

Resolve the **current** source and permissions, not a historical version requested
by the candidate. Version, reference and kind must match the declaration. AgentKit
computes `Knowledge.digest(content)` from the actual exact string (canonical JSON
SHA-256; not raw-file SHA-256). A provider-supplied digest cannot replace this check.
`observed_at` is the time the actual source was observed, not when a stale cache
entry was read. Future or over-age observations fail. Source text is at most 64 KiB;
do not silently truncate a source or omit relevant exceptions to pass this limit.
Use a separately versioned, domain-reviewed projection when needed.

```ruby
text = "Returns require an invoice. No automatic refunds."
draft = library.propose(
  id: "returns-draft-1", topic: "returns-policy", kind: "wiki", ttl: 86_400,
  sources: [{ id: "policy", reference: "policies/returns", version: "2026-11-06.1",
    digest: Agentkit::Knowledge.digest(text), kind: "document", max_age_seconds: 300 }],
  claims: [{ text: "Returns require an invoice", kind: "assertion",
    evidence: [{ source_id: "policy", quote: "Returns require an invoice." }] }],
  context: agent_ctx
)
```

Claim kinds are `assertion`, `reported`, `hypothesis`. Each claim has exactly
`text`, `kind`, `evidence`; each evidence entry has `source_id`, `quote`. Quotes
must be nonempty exact substrings of the checked source. An `assertion` cannot be
supported exclusively by user statements/model outputs: use `reported` or
`hypothesis`. Other source kinds still require semantic verification.

Limits: 1..32 sources, 1..32 claims, 1..16 citations/claim, 4096 bytes per claim,
quote/reference/version/review reason, 256 KiB total proposal. IDs/topics are
1..128 ASCII letters/digits or `:._-`. Source IDs are unique. TTL and source age
budgets are positive integer seconds, at most one year. TTL starts at proposal.

The candidate stores quoted excerpts, source identifiers/digests/versions and
observation times, not a second complete source archive. Rails must retain and
authorize originals under its privacy policy. The Journal also contains excerpts;
source redaction alone does not erase previously persisted quotations. Treat all
historical/candidate access as sensitive and implement retention/purge requirements
in the host. Do not retain secrets by default.

Retries with the same ID/request return the original candidate. A changed request
conflicts. A loader error or source mismatch prevents creation; wrong scope raises
`AccessDenied`. Proposed memories never enter normal retrieval automatically.

## Review, revisions and concurrent writers

```ruby
reviewed = library.publish(id: "returns-draft-1", expected_revision: 0,
  reason: "Checked policy scope and exceptions", context: human_ctx)
```

The verifier receives the candidate plus `source_contents`, keyed by source ID,
containing full checked loader responses. It returns exactly
`{ accepted: true/false, reasons: ["..."] }`. Reasons must be at most 32 strings of
1024 bytes. Nonempty reasons prevent publication even with `accepted: true`.
Source changes, expiry or verifier exceptions produce a durable rejected receipt;
an unavailable verifier does not silently approve. Only exception classes are
recorded, not potentially sensitive error messages. Access denials abort.

Publication locks the topic head, checks `expected_revision` and atomically writes
an immutable Journal revision plus the new head pointer. Two publishers expecting
the same revision cannot both succeed. A conflict requires fetching current state,
reviewing differences and proposing/reviewing a deliberate merge; no last-writer-wins
overwrite. Verifier version changes require a new candidate. Callbacks execute
under the transaction; enforce strict I/O timeouts and never perform business writes
or send notifications from them. Remote sources are not a distributed transaction.

`kind: "wiki"` uses the same safe publication path as `note`; a topic is one
versioned representation with evidence-linked claims. Existing `TeamMemory::Wiki`
pages are not silently imported or declared verified. Its graph diagnostics remain
useful for navigation; a graph snapshot marked validated is not semantic validation
of its prose. Host readers can project a reviewed topic into a UI, but must use
`current` before relying on it. No new autonomous wiki builder is enabled.

## Retrieval, invalidation and revocation

```ruby
current = library.current(topic: "returns-policy", context: reader_ctx)
history = library.revision(topic: "returns-policy", number: 1, context: reviewer_ctx)

# In an authorized Rails source-change consumer:
library.invalidate(reference: "policies/returns", reason: "Policy replaced", context: worker_ctx)

# Emergency withdrawal with an explicit revision expectation:
library.revoke(topic: "returns-policy", expected_revision: 2,
  reason: "Interpretation needs correction", context: human_ctx)
```

`current` checks source access, current version/content/classification, source age,
memory TTL and verifier version on **every** retrieval. Failure marks an active head
stale in a new immutable revision and returns nil. Permission/scope denials raise
instead of leaking content or marking another user's memory valid. Consequently
fresh retrieval can write a stale-state record and needs Journal write permission.
A temporary source outage conservatively invalidates; recovery requires a new
candidate/review, not silent reactivation.

Invalidation scans the caller's scoped heads in batches, affects only matching
source references, and is atomic per topic, not across all topics. Retries skip
already-stale heads. Host event consumers should call it after changes/deletion/
redaction. Retrieval checks remain necessary if an event is delayed or lost.
Only declared direct dependencies can be checked: include every underlying source
used by a synthesis. Arbitrary prose links are not an automatic dependency graph.

`head` and `revision` return historical state without source revalidation. They are
audit APIs, not fresh authority. A replayed publication receipt is also historical,
even if it originally said `active`. Use `current` for current usability.
Invalidation/revocation increments the same revision counter used for publication.
There is no blind rollback: restoring an older interpretation requires fresh source
checks and a new reviewed revision. No source evidence is deleted or superseded.

## Small initial context, explicit retrieval

```ruby
index = library.compile_index(topics: ["returns-policy"], context: reader_ctx, max_bytes: 4096)
fragment = index.fetch(:compilation).fragment
omitted = index.fetch(:omitted_topics)
```

The host selects up to 32 unique topics. Each is revalidated first; only current
representations contribute pointers. Indexes use ContextMap and its configured
source/global limits. Byte budget is 256..16384; entries are omitted whole, not
partial assertions. The fragment identifies topic and revision but does not inject
claims. Follow a pointer through `current` when needed. Injecting this untrusted
data fragment into an agent remains an explicit host decision. Original records
remain the authority for stock, balances, order state and execution decisions.

## Legacy compatibility and integration

Legacy `Cognition::Dreaming` now generates `imagined` hypotheses with zero confidence,
no candidate embeddings, source IDs/digests and candidate metadata. It never
supersedes observations, even with legacy `supersede: true`. A synthesis is not
evidence of improved confidence. `LayeredPipeline` L1 notes are reported candidates;
downstream scene/persona assets are quarantined. Previously stored memories are
not relabeled: audit legacy insights before relying on them.

Convert useful candidates to explicit typed claims/source declarations for this
review path. `Memory.promote!` means embedding promotion, not verification.
`Memory::Continuity` notes and `ExperienceLibrary` lessons keep their existing
contracts; their digests do not provide original text by themselves. Supply scoped
loaders for retained transcripts, experiment records or domain documents. This
feature does not register skills, infer Knowledge rules, or authorize interventions.

## Evaluation before rollout

`Memory::Evaluation.compare(cases:, runner:, grader:,
consolidation_cost_microusd: 0)` runs three arms: `search_only`, `current_memory`,
`consolidated_memory`. Fixtures contain exactly `id`, `input`, `expected` (1..200
unique cases, 2 MiB total). The runner receives only `(arm, input)`, never expected
answers; it returns exactly `answer`, `evidence_ids`, `tokens`, `cost_microusd`.
Answer limit is 64 KiB; at most 64 evidence IDs. Counts/costs are nonnegative integers.

The independent host grader receives `(output, expected)` and returns boolean
`correct`, `supported`, `stale_used`, `cross_scope`. A case passes only when correct,
supported, not stale and not cross-scope. The report preserves per-case grades,
fixture/output digests, measured runner+grading latency, tokens and reported costs.
Consolidation cost is charged once to the consolidated arm. Errors fail the case
and mark cost accounting incomplete, not a free successful run. Error text and full
answers are not persisted in the report.

Use isolated fresh runners and equivalent models/data per arm. Keep holdout answers
out of consolidation and retrieval sources; this API does not sandbox callbacks or
prevent a host from leaking labels. Account for recurring maintenance, source reads,
grading and provider costs explicitly. Host-reported numbers are not invoices or
statistical significance. There is no automatic promotion or causal conclusion.
Use existing governed evaluation/holdout mechanisms for repeated trials and review.

Start shadow-only, evaluate contradictions/stale sources/revoked access/concurrent
writers, then enable reviewed publication. Schedule background work only when the
measured benefit justifies cost. This implements a controlled memory lifecycle,
not an always-running autonomous learning service.
