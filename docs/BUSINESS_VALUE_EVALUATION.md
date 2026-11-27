# Paired business-value evaluation

`Harness::BusinessValueEvaluation` is an opt-in deterministic report over
versioned, host-measured process runs. It compares the current process
(`baseline`) with a candidate on exactly the same cases. Cases are split into
`training` and disjoint `holdout`; case IDs cannot be reused across phases.
This adds no model call, database migration, deployment or automatic promotion.

Each case declares an ID, category, phase and SHA-256 input digest. For every
case, the host supplies one baseline and one candidate observation with the
same input digest, separate SHA-256 evidence receipts, a verified-result flag,
safety-failure codes, and measured integer cost in micro-USD, tokens, latency
in milliseconds and human time in seconds. Missing measurements, duplicate
receipts, mismatched inputs or unpaired cases fail closed. Use trusted provider,
business and human-review logs for the measurements; an agent's own statement
is not a verified result.

```ruby
evaluation = Agentkit::Harness::BusinessValueEvaluation.new(
  id: "returns-eval", version: "policy-3",
  cases: [
    { id: "approved", phase: "training", category: "verified_refund",
      input_digest: Agentkit::Knowledge.digest("approved-fixture-v1") },
    { id: "missing-proof", phase: "holdout", category: "incomplete_evidence",
      input_digest: Agentkit::Knowledge.digest("missing-proof-fixture-v1") }
  ],
  observations: measured_baseline_and_candidate_receipts
)
report = evaluation.to_h
```

The report gives per-phase verified counts, safety failures, total cost,
cost per verified result, human time, latency and tokens. It also reports
candidate regressions by case and differences from baseline. A result with
any safety failure is not counted as verified. Cost per verified result is
undefined when no case passes, not zero. No phase is silently omitted.

The [returns reference application](../examples/returns_app/README.md) supplies
an integration target: its tests exercise independent approval, a changing
request, a lost provider response, expired lease recovery and a controlled
routing pilot. To evaluate real value, the Rails host should record the same
versioned fixture or live cohort on both arms, obtain final provider outcomes,
measure handling time from independent clocks, and populate this report from
those receipts. Include customer harm and correctness as safety failures.
Do not treat a single simulated demo refund as evidence of improvement.

This is a descriptive paired report. It does not estimate causal effect or
statistical significance and sets `causal: false`, `authorizes: false` and
`auto_promoted: false`. For promotion, pass a sufficiently powered controlled
experiment and the existing independent review gates. Hosts own fixture
retention, redaction, collection completeness and run scheduling. Re-evaluate
after changing a model, policy, verifier, pricing source or process version.
