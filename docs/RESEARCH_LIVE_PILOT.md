# Live OpenAI research pilot

On 2026-11-27, the optional [live script](../examples/research_workflow_live.rb)
called OpenAI `gpt-4o-mini` through `Agentkit::LLM.turn`. It reads only
`OPENAI_API_KEY` from the environment or the repository's ignored `.env` file;
it never prints the key. Run it with:

```bash
bundle exec ruby -Ilib examples/research_workflow_live.rb
```

The script runs two **synthetic, host-owned** policy cases, one training and
one holdout, three times each. The single-agent arm makes one model call with
both versioned sources; the split arm makes one call per source and joins the
claims. Both arms use the same questions, source snapshot, model and prompt.
The order of arms alternates across repetitions. A separate `verifier`
principal checks the report against the current source content. The run uses
`Flow.test_mode!`, so split calls are sequential rather than concurrent jobs.
No web search, real business data or human reviewer participates.

## Observations

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

## Decision boundary

The result supports keeping a single researcher as the default for this small
literal-extraction task. It also demonstrates that source-backed verification
catches an omission that a plausible report could hide. Two distinct cases
repeated three times are insufficient to infer population quality or the
value of parallel research on harder tasks. Before changing a production
topology, evaluate independent real tasks with the same source snapshots,
provider usage, reviewer time and an async Rails deployment. The paired
`BusinessValueEvaluation` report has `causal: false` and never promotes an arm.
