# Agent memory continuity (opt-in)

AgentKit keeps five kinds of state separate. None of the APIs below adds an LLM call or requires embeddings. The Rails host remains responsible for choosing what user data may be retained, setting retention policy, and authenticating reviewers.

## Current context

`Agent#run_loop` limits total context bytes. When an older completed tool exchange can be removed safely, it compacts the old messages into a digest marker, preserving the initial request and the most recent assistant/tool exchange. The marker is **not** evidence that a tool succeeded. If the remaining exchange still cannot fit, the loop returns `context_limit`. This deterministic compaction does not semantically summarize old messages.

## Task notes and episodes

Pass a trusted task ID to enable continuity:

```ruby
ctx = Agentkit::Context.new(user: current_user, account: current_account,
                            principal: "user:#{current_user.id}")
result = SupportAgent.new(context: ctx).run_loop(
  "Check the invoice", task_id: "invoice-review-42",
  task_summary: "Review invoice 42 and verify the source"
)
note = Agentkit::Memory::Continuity.latest(task_id: "invoice-review-42", context: ctx)
episodes = Agentkit::Memory::Continuity.search_episodes("invoice", context: ctx)
```

The loop checkpoints a bounded note after each completed tool turn and at exit. A subsequent loop with the same task ID receives the latest note in its context. This resumes the **task intent and recorded progress**, not the exact model transcript or an unfinished external action. Checkpoints are durable, supersede their predecessors, and are isolated by tenant/account and principal. Episodes retain the supplied summary, outcome, digest and evidence references for the standard 90-day retention policy. Avoid putting secrets in `task_summary`. Without `task_id`, the loop retains no new task notes or episodes.

## User and project facts

```ruby
Agentkit::Memory::Continuity.remember_fact(
  subject: :user, key: "editor", content: "Prefers Neovim", context: ctx
)
Agentkit::Memory::Continuity.facts(subject: :user, query: "editor", context: ctx)
Agentkit::Memory::Continuity.remember_fact(
  subject: :project, key: "repo", content: "Rails monolith", context: ctx
)
```

Facts are explicit writes, durable, keyword-searchable, and replaced by key without deleting history. User facts require `context.user` and are filtered by user ID; project facts are shared within tenant/account. The host should obtain consent and use `MemoryReviews` when a fact needs human review. No automatic extraction of personal facts from chat occurs.

## Procedures

`TeamMemory::SkillExtractor.extract(conversation: real_transcript)` creates a **quarantined** procedure candidate from explicit steps. It no longer registers the prompt immediately. After an authenticated reviewer examines the candidate, the host can call `review_and_activate!(asset, actor:, authorize:)` with a callback that verifies the reviewer's authority. Activation saves the asset but does not add it to the process-wide SkillRegistry; the host must explicitly bind it to an agent and equip that agent under the proper tenant/ACL scope. `Chat.say("mem:skill", transcript: real_transcript)` can create such a candidate; without the transcript it returns an instruction instead of a false success. `ExperienceLibrary` remains a separate evidence-gated way to retain lessons from successful experiments.

The L0→L3 `LayeredPipeline` is a set of explicit transformations, not an always-running background process. Neither a quarantined skill nor a persona asset becomes available to an agent merely because it was extracted.
