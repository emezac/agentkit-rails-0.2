# SDD — Architecture Evaluation 1.5.1

## Purpose

Assess whether a specialist should become skills/tools in a main loop using
task completion, production-chain coverage and observed delegation coupling.
The implementation adds optional contracts to GovernedStudy; AgentLoop and
progressive skill/tool loading remain future runtime work.

Reference: https://claude.com/resources/articles/building-agents-when-to-fold-subagents-into-your-main-agent-loop

## Task and phase contract

ArchitectureEvaluation configures minimum_success_rate (default 1), maximum
regressed tasks (default 0; nil disables this limit), and required ordered chains.
ExperimentTask.metadata.architecture declares chain, critical and required_checks.
All names and lists are bounded. Candidate executors return explicit boolean
success and check verdicts on every repeated probe. Grading is host owned.

Required checks must be present. A false required check counts against effective
success and blocks the gate independently of the regression allowance.
Critical tasks must meet the configured success rate even if the baseline failed.
A regression means any reduction in task success rate, not only crossing the
pass/fail threshold. The report separately counts pass_to_fail and fail_to_pass
transitions and records quality/cost/latency deltas. Quality is never assumed
to be a binary completion grade.

Each required production chain must have a declared task in training and in
holdout. Sequence and full path matter; reverse or partial paths do not cover a
chain. This is testcase coverage, not proof of actual runtime behavior. Host
graders encode procedural requirements as checks when needed.

Training selects only candidates passing architecture gates. If none qualify,
baseline is retained. Holdout tests the frozen winner against baseline; a failed
architecture gate blocks recommendation regardless of statistical quality gains.
Governance also checks attached training/holdout gate results. Neither diagnosis
nor report persistence promotes a candidate.

## Delegation diagnosis

DelegationDiagnostics accepts an explicit scoped trace export and agent catalog.
It excludes unknown fields (including prompts/outputs) from its normalized report
and source digest. Request ids are hashed. Cross-tenant/account inputs, duplicate
request ids/catalog entries, invalid numerics and excessive batches are rejected.

Inputs describe peer invocations in a request, with start and duration in ms.
Nested coordinator spans must be removed by the host exporter. Sequential paths
are inferred only when every peer span is non-overlapping; concurrent or overlong
paths are marked nonlinear. Report.required_chains provides these observed paths
for explicit inclusion in the evaluation policy. It is not automatically applied.

Per-agent rows record request/call counts, durations and known usage. Missing
usage includes completeness flags. Pair rows report shared-request rate,
sequential adjacency and overlap. Merge requires the minimum request count,
configured serial/union frequency, matching context_group and no overlap or
declared isolation. Verification, permission boundaries, independent contexts and
observed parallel work favor keeping a specialist callable as a tool. Known
router/planner/domain roles with a declared shared context group can be fold
candidates; uncertain boundaries or sparse data remain inspect/insufficient.
These are diagnostic hypotheses and do not prove causal quality improvement.
No tracing middleware is installed and no runtime graph is changed.

Bounds: 200 traces, 64 agents, 64 calls per trace, 2,000 calls overall, 32 names
per chain, 64 check names per task, 200 required chains and the existing report
byte budget. Source ordering is normalized for stable report identity.

## Reports and dashboard

Passing and blocked training/holdout reports are explicitly stored using the
existing Memory port (durable, imagined, no embedding). Report id hashes the
normalized payload; metadata stores a second integrity digest. Re-recording the
same evidence is idempotent; identical concurrent rows collapse on read.
Writes are not a distributed transaction spanning all candidate reports.

Reports include scope, study identity, selected candidate, per-task evidence and
coverage. Training records include the full evaluation selection digest; holdout
records also include persisted world digests and statistical comparison.
Optional delegation reports are committed to the study digest and retained in
review evidence and diagnostic reports. Raw probe bodies and imported prompts
are absent. Reports obey max_checkpoint_bytes; disabled writes fail visibly.
Retrieval validates exact scope and integrity, then returns latest bounded rows.
Memory history is scanned; large archival analytics are outside this version.

The protected exploration dashboard lists blocked evaluations without requiring
a promotion dossier. It shows phase, candidate, regressions, critical cases,
checks, coverage, task deltas and delegation proposals under existing console
access/CSRF/no-store protections. Existing review actions remain available only
through the normal governance flow.

## Compatibility and verification

No schema change. Optional fields are absent from legacy evaluation serialization
and optional digest fields are omitted when unused. Distributed workers register
identical policy/diagnostic data, preserving scope and study identity.

Unit verification covers statistically improved but procedurally regressed cases,
single-repeat failures, regression allowance, mandatory checks, ordered coverage,
training rejection, read integrity, write failure, isolated import and protected
delegation boundaries. PostgreSQL/Active Job verification covers report reload,
tenant/account isolation, blocked dashboard rows, successful promotion/rollback
and registry recovery for opted-in workers.
