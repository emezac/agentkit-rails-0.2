# SDD — AgentKit Harness Experiments 1.4.0

Status: implemented

Date: 2026-10-23

## Problem

AgentKit 1.3 makes one execution harness explicit and verifiable, but it does
not provide a safe way to test changes to that harness. A model can suggest a
better prompt, skill or tool policy, yet without a stable base manifest,
matched executions and evidence-linked attribution the suggestion is difficult
to reproduce and unsafe to reuse.

Version 1.4 introduces a bounded meta-loop inspired by Harness²:
`Propose -> Probe -> Compose`. It adapts the method to AgentKit's existing
trust boundaries. Candidates are declarative patches, probes run only in an
isolated host-owned executor, and a composition never activates itself.

## Goals

1. Give every harness component a typed, immutable and digest-addressed form.
2. Express candidates as reviewable patches over one exact base manifest.
3. Reject unsafe or malformed candidates before execution.
4. Compare baseline and candidates under the same task, model and environment.
5. Attribute every change to observed evidence without claiming correctness.
6. Make `KEEP_BASE` a first-class, evidenced result.
7. Preserve only references and digests in experiment results and Audit.

## Non-goals

- Training or modifying model weights.
- Executing candidate-provided Ruby, shell, plugins or network clients.
- Proving correctness from behavioral difference alone.
- Automatically promoting a selected manifest into production.
- Persisting a cross-task experience library; that is deferred to 1.4.1.
- Replacing Adaptive Exploration holdout, statistical or human-review gates.

## Manifest model

`Harness::Component` supports eight declarative types:

- `system_prompt`
- `guardrail`
- `memory_policy`
- `skill`
- `tool_guidance`
- `capability`
- `subagent`
- `middleware`

A component records a stable `type:name` key, version, JSON configuration,
activation rule, dependencies, resource declarations, permissions, risk,
effect and metadata. Callables are not serializable and fail construction.
There is intentionally no generic `script` component.

`Harness::Manifest` contains a bounded set of components and the task-defined
output contract. Its digest covers the complete canonical representation. A
revision cannot edit the output contract.

`Harness::Revision` contains `add`, `replace` or `remove` changes and targets
one exact base digest. A revision is scoped as either:

- `invariant`: planning, verification, context or tool-use behavior expected
  to transfer across a domain;
- `domain`: knowledge, procedure or constraints specific to one domain.

Removal is disabled by the default validator because deleting a guardrail can
widen effective authority without changing an `effect` label. Hosts must opt
in with `CandidateValidator.new(allow_removals: true)` for a controlled case.

Applying a revision creates a new immutable manifest with the prior digest and
revision provenance. It never mutates the base.

## Candidate validation

`Harness::CandidateValidator` runs before a candidate reaches the executor.
It returns an immutable `ValidationReport` rather than partially accepting a
candidate.

The validator checks:

- structural applicability to the exact base digest;
- component, manifest, revision and context-size budgets;
- no increase in effect or risk;
- no permission not already present or explicitly allowed by the host;
- no resource matching goal-protected or scope-excluded patterns, and no
  declared resource outside a non-empty goal include scope;
- an explicit activation trigger for new or changed skills;
- complete component dependencies;
- preservation of the exact output contract.

Invalid candidates have evidence-bearing validation reports but receive no
probe. When no valid candidate exists, the experiment returns an automatic,
evidenced `KEEP_BASE`.

## Matched probes

`Harness::ExperimentTask` freezes the identity of:

- task input reference and digest;
- model configuration and digest;
- environment configuration and digest;
- output contract.

The environment must be sandboxed, have network disabled and isolate side
effects. This is a contract checked by AgentKit; the injected host executor is
responsible for enforcing the actual operating-system boundary.

The same task/model/environment identity is attached by the control plane to
every baseline and candidate `ProbeResult`. An experiment supports bounded
repetitions to expose stochastic variance. Executor failures become redacted
failed probes, not hidden retries.

A successful probe stores an output reference and digest. If the executor
returns a raw output only to calculate that digest, AgentKit discards the body.
Observations, numeric metrics and external evidence references remain bounded
control-plane data.

## Behavioral contrast

The host contrastor receives immutable probe snapshots. It must return exactly
one `ChangeAttribution` per revision change with one of:

- `helped`
- `hurt`
- `no_observed_effect`
- `confounded`

Every attribution requires a concrete observation and references produced by
the matched probes. Unknown evidence fails closed. A contrast containing any
`confounded` attribution is marked unsuitable for a reusable lesson; adoption
of a whole candidate does not imply every edit helped.

Behavioral contrasts document observed differences. They are not ground-truth
verification and do not replace `Harness::Verifier`.

## Composition

The composer receives immutable manifests, revisions, validation reports,
probe results and contrasts. It may return:

- `KEEP_BASE` / `keep_base`;
- `adopt` with one valid proposed revision;
- `compose` with a new revision against the original base.

A composed revision passes the same validator before selection. Every
composition reason requires evidence produced by the current experiment.
Unknown or invented references fail closed.

The result is advisory. `selected_manifest` is returned to the host but no
Skill registry, Capability, policy binding or live agent is modified.

## Audit and telemetry

The runtime emits:

- `harness.experiment.started`
- `harness.experiment.completed`

Completion measures candidate, valid-candidate, probe, contrast and confounded
change counts. Audit stores experiment/result/task/manifest/revision digests,
counts and the composition action. Raw task inputs, outputs, prompts and error
messages are excluded; executor error messages are represented by a digest.

## Limits

The `config.harness` defaults are:

| Setting | Default |
| --- | ---: |
| `max_manifest_components` | 64 |
| `max_manifest_bytes` | 128 KiB |
| `max_component_bytes` | 16 KiB |
| `max_revision_changes` | 16 |
| `max_experiment_candidates` | 8 |
| `max_probe_repetitions` | 5 |
| `max_context_delta_bytes` | 32 KiB |

All must be positive integers.

## Trust boundaries

- Proposer, executor, contrastor and composer are host-owned adapters.
- Callback requests are deeply frozen snapshots.
- Candidate configuration is untrusted JSON data.
- Static validation is necessary but does not authorize domain effects.
- The host sandbox enforces filesystem, process and network isolation.
- Probe evidence can support comparison but not certify correctness.
- Production promotion remains under holdout, Governance, HITL and rollback.

## Compatibility and rollout

No database migration is required. Existing goals and schema-v1/v2
checkpoints remain unchanged.

Recommended rollout:

1. Model one existing harness without running experiments.
2. Validate manifests and revisions in CI.
3. Add a deterministic fake executor and contrastor.
4. Enable sandboxed probes with at least two repetitions for stochastic tasks.
5. Observe `KEEP_BASE`, invalid-candidate and confounded rates.
6. Feed only statistically confirmed candidates into the existing governed
   promotion workflow.

Verification command: `bundle exec rake verify`.
