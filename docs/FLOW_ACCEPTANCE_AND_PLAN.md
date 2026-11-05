# Flow acceptance and dependency plans

`Flow` can check a read-only step before downstream steps use its result. The check is deterministic host code: tests, a schema validator, or a source-integrity check. A model's confidence or another model's opinion is not a substitute for a check.

```ruby
class ExtractOrderFlow < Agentkit::Flow
  version 2
  step :extract, agent: OrderExtractor, effect: :read_only,
    accept: ->(value, _ctx) {
      valid = OrderSchema.valid?(value)
      valid ? true : { accepted: false, reason_code: "schema_invalid" }
    },
    repair: ->(value, _ctx, attempt, reason_code) {
      OrderNormalizer.call(value, reason_code: reason_code)
    },
    max_repairs: 2
  step :use, depends_on: [:extract] do |ctx|
    ctx[:extract].value
  end
end
```

`accept:` receives `(candidate_value, flow_context)` and returns exactly `true`, `false`, or `{ accepted: true/false, reason_code: "safe_code", evidence_digest: "sha256:<64 hex>" }`. A rejected hash needs a short reason code; the optional digest can refer to independently stored test evidence. The accepted step row stores its result digest, checker identity (`flow:version:step`), optional evidence digest, and repair count. Rejections persist only a candidate digest, reason code and optional evidence digest in `attempts`, not the candidate body. Bump the Flow version when changing the checker.

`repair:` receives `(candidate_value, flow_context, repair_number, reason_code)` and returns a replacement value. It should be a bounded, pure transformation. It does not rerun the original step, earlier steps or sibling branches. `max_repairs` is 0 by default and at most 3. A repeated rejected candidate stops immediately; exhausted repairs, exceptions and invalid verdicts fail the step and run. `accept:` and `repair:` are allowed only on steps declared `effect: :read_only`. Side effects still require the existing Actions and human approval controls. This option does not add LLM calls; host callbacks can incur their own costs, which the host must account for.

`Flow.explain_plan` now exposes `dag.execution_edges` for the current sequential order and `dag.declared_data_edges` for explicit `depends_on:` relationships. It validates missing or forward dependencies at boot. `parallel_review_candidates` lists adjacent read-only steps marked `ordering: :any` with no declared data dependency. These are suggestions for human review; Flow does not silently change execution order. `estimated_serial_path_ms` names the current sequential estimate. `estimated_critical_path_ms` remains for compatibility and uses the same estimate; it is not a promise of parallel speedup.
