# Verifiable research example

Run the offline example with `ruby -Ilib examples/research_workflow.rb`. It
requires no model, network, database or migration. The fixture contains twelve
synthetic policy-research cases, six for training and six for holdout. Ten were
added after the initial two-case pilot: shipping, cancellations, warranty,
address changes, loyalty points, partial refunds, gift cards, fraud review,
inventory and contradictory priority-delivery promises. Gift cards and fraud
review include questions without an answer; the priority case includes two
conflicting primary sources. Each case uses the
same questions and source IDs in both arms:

- `SingleResearch` uses one researcher over the whole source set.
- `SplitResearch` uses `Flow#map` to give each branch one source and joins all
  branch results before producing a report.

In the standalone command, `Flow.test_mode!` executes map branches in the
same process. A Rails host can run the flow through its async dispatcher to
execute branches as separate jobs. This fixture does **not** establish a speed
or quality improvement from delegation.

## Report contract

Every report has `case_id`, `source_snapshot_digest`, `claims`, `unresolved`
and `authorizes: false`.
Each claim names one question and includes a source ID, reference, version,
content digest, and literal quote. The host-owned `SourceRepository` scopes
reads to a tenant and an allowed role. A separate `verifier` principal uses
`ReportVerifier` to reread the current source and check the declared snapshot
digest, source digest/version/reference and quote. A claim must quote the exact
answer text and contain the question's search term;
every question must have exactly one claim or one unresolved entry. Declaring
an answerable question unresolved fails verification. Distinct matching source
texts are conservatively reported as `conflicting_sources` until reviewed. The
holdout fixture demonstrates a genuine missing answer.

The fixture checks literal evidence only. A matching quote does not establish
that a paraphrase or inferred conclusion is true. For nonliteral claims, add
an independent domain grader or human reviewer with its own access to source
versions. Treat source content and worker output as untrusted data, and keep
authorization in the host rather than in model-provided references.

## Paired evaluation

`ResearchWorkflowExample.compare` executes both arms for each case, verifies
their reports, and passes paired observations to
`Harness::BusinessValueEvaluation`. It produces separate training and holdout
summaries, candidate regressions, and an explicit `causal: false` /
`auto_promoted: false` boundary. `input_digest` is identical for the two arms
of each case; each result has a distinct evidence digest.

The offline fixture has zero tokens, model cost and human review time. Its
measured wall-clock latency is only a smoke-test measurement. Do not use its
numbers to select an architecture. For a real study, use the same versioned
source snapshot and questions in both arms, run repeated probes on disjoint
training and holdout cases, and record observed provider usage, reviewer time,
correctness of citations, unresolved coverage, cross-tenant failures and
latency. Use `GovernedStudy` / `Organization::CompositionStudy` when the
decision needs statistical or topology governance; production promotion
remains human-owned.

## Rails responsibilities

The host replaces the fixture `SourceRepository` and `ResearchTrack` with
tenant-authorized, versioned source loaders and an LLM/search adapter. It
controls which source IDs enter each track, caps fan-out, enforces provider
budgets and timeouts, persists run and source snapshots, and gives the
verifier a separate authorization path. Keep expected outcomes and grading
rules out of worker inputs. `Flow` handles orchestration; Rails supplies
workers, storage, source freshness and any external search permissions.

Related contracts: [Flow](../README.md), [organizational evaluation](ENDOGENOUS_ORGANIZATION.md),
[paired business value](BUSINESS_VALUE_EVALUATION.md), and
[offline SaaS evals](OFFLINE_SAAS_EVALS.md). An optional
[live OpenAI pilot](RESEARCH_LIVE_PILOT.md) records a small real-model run
without adding a network call to the test suite.
