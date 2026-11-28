# Live OpenAI research pilot

On 2026-11-27, the optional [live script](../examples/research_workflow_live.rb)
called OpenAI `gpt-4o-mini` through `Agentkit::LLM.turn`. It reads only
`OPENAI_API_KEY` from the environment or the repository's ignored `.env` file;
it never prints the key. Run it with:

```bash
bundle exec ruby -Ilib examples/research_workflow_live.rb
```

The first pilot ran two **synthetic, host-owned** policy cases, one training and
one holdout, three times each. The current script runs twelve cases, six per
phase; `RESEARCH_REPETITIONS` sets one to three repeats per case. The
single-agent arm makes one model call with
both versioned sources; the split arm makes one call per source and joins the
claims. Both arms use the same questions, source snapshot, model and prompt.
The order of arms alternates across repetitions. A separate `verifier`
principal checks the report against the current source content. The run uses
`Flow.test_mode!`, so split calls are sequential rather than concurrent jobs.
No web search, real business data or human reviewer participates.

## Initial two-case pilot

An initial, less explicit prompt produced 3/3 verified training runs in both
arms. In holdout, the single arm passed 3/3 while the split arm passed 0/3:
the branch holding the damaged-item policy returned an empty claim list.
The verifier marked its omitted answer `false_unresolved`. A targeted call
showed the branch could quote the answer when instructed to check each
question independently. This is an observed prompt sensitivity, not proof of
a general architecture effect.

The final prompt explicitly requires checking every question against every
source. The same 18-call protocol then produced:

| Arm | Verified training | Verified holdout | Calls | Tokens | Estimated cost | Total local latency |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Single | 3/3 | 3/3 | 6 | 1,497 | $0.000444 | 10.742 s |
| Split | 3/3 | 3/3 | 12 | 2,323 | $0.000577 | 14.241 s |

The split arm used 55% more tokens and about 30% more estimated token cost,
with no observed quality gain in these cases. Cost uses the provider-reported
token counts and the [published `gpt-4o-mini` rates](https://developers.openai.com/api/docs/models/gpt-4o-mini)
of $0.15 input and $0.60 output per million tokens. It is an estimate, not a
billing statement. Local latency includes sequential `Flow` execution and
does not estimate the latency of parallel Rails jobs.

## Expanded twelve-case pilot

Ten additional cases cover shipping, cancellations, warranty, address
changes, loyalty, partial refunds, gift cards, fraud, inventory and two
conflicting priority-delivery policies. The prompt was made explicit about
checking every `(question, source)` pair before this expanded run. The
holdout cases were not tuned after observing their results. On 2026-11-27,
`RESEARCH_REPETITIONS=2` produced 24 paired attempts and 72 provider calls:

| Case | Phase | Single | Split |
| --- | --- | ---: | ---: |
| Returns | Training | 2/2 | 2/2 |
| Shipping | Training | 2/2 | 2/2 |
| Cancellations | Training | 2/2 | 2/2 |
| Warranty | Training | 2/2 | 0/2 |
| Address change | Training | 2/2 | 2/2 |
| Loyalty | Training | 2/2 | 2/2 |
| Refunds | Holdout | 2/2 | 2/2 |
| Partial refund | Holdout | 2/2 | 2/2 |
| Gift cards | Holdout | 0/2 | 0/2 |
| Fraud | Holdout | 2/2 | 2/2 |
| Inventory | Holdout | 2/2 | 2/2 |
| Priority conflict | Holdout | 2/2 | 2/2 |
| **Total** | | **22/24** | **20/24** |

| Arm | Calls | Tokens | Estimated cost | Total local latency |
| --- | ---: | ---: | ---: | ---: |
| Single | 24 | 6,340 | $0.001790 | 38.155 s |
| Split | 48 | 10,022 | $0.002394 | 54.226 s |

The split arm lost two paired attempts and gained none. It used more tokens
in all 24 pairs: 58% more tokens and about 34% more estimated token cost in
total. Its local sequential latency was 42% higher. The warranty source was
omitted by the split arm twice. Both arms omitted the answerable gift-card
cash rule twice. In diagnostic calls, the model returned `claims: []` for
those matching source texts; the verifier correctly reported
`false_unresolved`. Both arms correctly reported the priority-policy conflict
as unresolved. [Per-attempt metrics and issue codes](data/research_pilot_12_cases_2026-11-27.json)
are retained without prompts, credentials or raw provider responses.

## Decision boundary

The expanded result supports keeping a single researcher as the default for
this small literal-extraction task. It also demonstrates that source-backed
verification catches omissions that a plausible report could hide. The 24
attempts contain only twelve distinct synthetic cases; repeats are not
independent examples. These results do not estimate population quality or the
value of parallel research on harder tasks. Before changing a production
topology, evaluate independent real tasks with the same source snapshots,
provider usage, reviewer time and an async Rails deployment. The paired
`BusinessValueEvaluation` report has `causal: false` and never promotes an arm.

For tasks that require literal substring evidence, the optional
[deterministic research gate](RESEARCH_EVIDENCE_GATES.md) now prepares quoted
claims from trusted sources before model synthesis. It passes all twelve
synthetic fixtures without a model call; inferred prose remains unverified.
