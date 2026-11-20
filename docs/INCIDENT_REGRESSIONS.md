# Critical incident regressions

Run from the gem checkout:

```sh
bundle exec rake quality:incidents
```

`rake verify` includes the incident gate, so the same gate runs in CI and
before building verified release artifacts.

The gate runs the RSpec cases tagged `incident:` three times in fresh Ruby
processes with distinct, reproducible random seeds. Each case must pass all
three times. A missing, duplicate, pending or failing case blocks the gate.
The initial cases cover false completion after rejected or stale review,
Flow resumption and loop boundaries, and LLM repair and budget accounting.
The cases execute public behavior with in-memory stores and the fake LLM
adapter. They do not measure the quality of an external model.

The JSON report includes each attempt's verdict and measured example runtime
in milliseconds. Provider cost is zero because the probes use no paid
provider. The summary uses `Harness::ArchitectureEvaluation` to keep the same
required-check and success-rate semantics as other harness evaluations. It
reports outcomes and timing without exception text or backtraces.

To add a case, capture the observed failure with an executable spec, tag the
example with a unique incident identifier and register its path in
`spec/support/incident_regressions.rb`. Run that spec directly with RSpec for
full failure diagnostics.
