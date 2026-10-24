# SDD — Governed Self-Improvement 1.5.0

## Contract

Opt-in Harness::GovernedStudy composes the 1.4 manifest validator with existing
distributed Exploration jobs, admission quotas, governance stores and console.
It measures real harness executions rather than replaying different controller
policies over a fixed exploration tree. Experience Library remains independent;
this release does not generate or activate learned lessons automatically.

## Study identity and safety

The study digest commits to tenant/account, candidate manifest digests, ordered
training/holdout task digests, repetition count, executor/judge version and
statistical settings. All candidates validate before any run. Task ids and input
digests must be unique across both cohorts; model/environment digests and output
contracts match. At least two repetitions and bounded task counts are required.
Hosts must ensure genuinely independent examples, judge version accuracy,
sandbox isolation and consistent metric units. Identity checks cannot discover
semantic duplicates or secretly reused evaluation data.

## Execution

Register identical study definitions on each worker. The registry holds executable
callbacks; queued worlds contain digests/assignments, not callables or raw inputs.
One world per task schedules each variant/repetition sequentially with rotated
ordering; workers parallelize tasks. Training probes all fixed candidates;
holdout probes baseline and one winner only. Bounds must fit configured
round/node limits instead of silently truncating the study.

Existing Active Job delivery, durable world checkpoints, leases, unknown-attempt
reconciliation and world/attempt quotas apply. Worlds are reloaded from the store
for evaluation (caller-supplied World objects are never trusted as evidence).
Failed, partial, duplicated, foreign-scope or mismatched worlds fail closed.
Duplicate delivery of a world is safe. Starting a phase again is a new batch;
hosts retain IDs and reconcile existing attempts rather than silently retrying.
This is not a distributed phase coordinator or an exactly-once external runner.

## Selection and statistics

Average repeats within each task. Form the training Pareto frontier by maximizing
quality and minimizing cost/latency with configured epsilon. Pick the highest
quality eligible candidate with deterministic cost/latency/name tie breakers;
require training quality improvement over the baseline. Freeze and revalidate
the training selection before holdout execution and recommendation.

Holdout compares only this frozen winner against baseline. Paired percentile
bootstrap resamples per-task quality differences, uses deterministic seed and
configured confidence/minimum effect, and requires minimum holdout task count.
Candidate must remain on holdout Pareto frontier. Retain when any gate fails.
An expensive but higher-quality Pareto tradeoff may pass; humans decide whether
that tradeoff is acceptable. Holdout cannot be used by this API to choose among
multiple candidates. Fresh holdout across cycles and avoiding cherry-picked
reruns remain host responsibilities, not a global dataset-lock service.

## Promotion, rollback and operations

submit! regenerates evidence from persisted worlds and sends only qualifying
recommendations into existing human-review governance. Dossiers include study,
scope, split, executor, manifests, aggregate metrics, confidence interval and
world digests. Evidence size is bounded. Raw outputs/errors are absent; hosts
must keep secrets out of declarative manifests.

Approval is atomic and refuses a changed incumbent binding in memory and SQL.
Bindings are declarative; active_manifest resolves a known validated digest or
fails closed. Rollback restores the preceding binding; without one, host base
is retained. The host authenticates and authorizes actors; console actions use
existing guard, CSRF protection, tenant scope and no-store headers.

The existing dashboard adds sample size, repetitions, confidence interval,
training frontier and holdout quality/cost/latency to harness review rows.
Queued/running/failed worlds and quota use remain in the shared operations view.
Rejected statistical gates do not create promotion dossiers.

## Verification and compatibility

Unit tests cover independent samples, negative holdout, Pareto tradeoffs,
immutable selection checks, disjointness, failure/quotas, tenant boundaries,
size limits, scoped governance and stale promotion. PostgreSQL/Active Job tests
cover registry reload, incomplete worlds, duplicate delivery, quota accounting,
approval/rollback and guarded dashboard rendering. No schema change required.
