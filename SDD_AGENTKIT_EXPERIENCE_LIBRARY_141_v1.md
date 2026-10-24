# SDD — Experience Library 1.4.1

## Scope

Implemented as Agentkit::Harness::ExperienceLibrary and immutable Experience.
The library turns explicit experiment evidence into reviewable procedural
hypotheses, not facts or automatically deployed harness changes.

## Admission and provenance

capture! validates exact tenant/account scope, a single validated revision change,
at least two successful matched baseline/candidate repetitions, and a helped/hurt
attribution referencing both groups. Ineligible evidence yields nil (NO_ENTRY).
This gate is not proof of statistical causality; experiment callbacks and
declared environments remain host responsibilities.

Each experiment/domain has one deterministic entry ID. Repeated capture is
idempotent; reused experiment IDs with different evidence are rejected.
Snapshots preserve task/result/base digests, revision, contrast and probe
references/metrics, excluding raw probe observations and error messages.
Caller-authored lesson text and declarative revisions require host redaction.

## Lifecycle and retrieval

candidate -> active or rejected; active -> stale, superseded or rejected;
stale -> superseded or rejected. Terminal entries cannot reactivate.
Supersession requires another active entry in the same library, providing
explicit consolidation without automatic semantic merging.
Transitions require actor/reason; authorization is supplied by the host.
TTL prevents retrieval immediately; maintain! previews by default and appends
stale transitions when applied. Durable snapshots are not deleted.

ContextMap selects relevant active entries under existing source/byte limits.
Content is labelled untrusted hypothesis and includes the result digest.
There is no automatic lesson generator or live harness activation.

## Persistence and integrity

Memory stores imagined, durable, non-embedded snapshots under harness_experience.
Every generation hashes its predecessor; missing history, digest mismatch or
branching versions fail closed. Hosts must serialize writes per experience:
this release does not implement transactional distributed compare-and-swap.
Hashes detect inconsistency, not malicious rewriting by a privileged store owner.
Entries are bounded by max_checkpoint_bytes; history scanning is intended for
small curated libraries, not unbounded archival search.

## Verification

Unit coverage includes provenance, idempotency, evidence rejection, negative
lessons, review transitions, expiration, supersession, isolation, disabled writes,
tampering and competing snapshots. ActiveRecord integration covers persisted
reload and tenant isolation. No schema migration is necessary.
