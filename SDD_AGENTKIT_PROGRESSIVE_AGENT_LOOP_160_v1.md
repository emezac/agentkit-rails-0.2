# SDD — Progressive Agent Loop 1.6.0

## Objective and boundary

Add an opt-in conversational runtime that can fold tightly coupled specialists
into skills/tools while preserving explicit delegation for independent contexts.
Existing declarative Flow and 1.5 governance remain intact. No code is migrated,
registered from model output or promoted automatically.

Reference: https://claude.com/resources/articles/building-agents-when-to-fold-subagents-into-your-main-agent-loop

## Native turn protocol

LLM.turn accepts normalized text messages and schema-only tools, resolves one
fixed model/profile and performs one provider request. Adapter responses contain
assistant content/tool proposals, stop reason and token usage. The harness
validates JSON data, bounded names/ids, arguments, unique call ids, usage and
message size before executing any proposal. Truncation/refusal/unsupported stops
withhold text and run no tools, even when tool proposals are present.

RubyLLMAdapter calls the SDK provider completion API directly with schema-only
NativeTool descriptors; Chat#ask/complete recursion cannot execute tools. Native
SDK retries are disabled, and there is no automatic cross-provider fallback.
Per-call SDK configuration copies carry credentials/timeouts. OpenAI-compatible
gateways use explicit provider configuration. Native reasoning blocks/signatures
are replayed in transient state, including Anthropic redacted blocks; user results
and loop audit do not expose them. Fake offers separate scripted native turns.

## Progressive disclosure and contracts

SkillCatalog snapshots declared skills, descriptors, prompts/providers and tools.
Initial system context contains metadata, not full procedures. A load evaluates
the procedure and context providers once per run. Provider context is labelled
untrusted. Procedure size is rejected rather than truncated. Activation succeeds
only when the complete procedure fits and permitted tool schemas fit active
tool bounds. Explicit repeated loads reuse rendered content.

ToolCatalog indexes declared ToolContracts. Search performs deterministic text
matching over authorized name/description and activates bounded matches. Invocation
checks the schemas offered on the preceding model turn plus current class
allow/deny, inherited policy, authorizers and contract digest. A skill's authorizer
applies to discovery/loading and to its tools; explicit host tools remain
separately declared. Duplicate/reserved/invalid names fail before execution.
Schema disclosure is not permission, and loading cannot grant authority.

Every invocation uses ToolContract schemas/preconditions/evidence/timeouts.
Non-read-only contracts continue to refuse direct effects; host operations use
the existing Actions/HITL entry points. Only reads explicitly marked parallel_safe
are batched concurrently, within max_parallel_tools. Controls/delegation are
serial, and output order follows input order. All workers join before a batch
returns, including failures. Error envelopes carry classes rather than raw
exception text. Large data results become bounded digest/preview envelopes.

## Runtime and finalization

AgentLoop is single-use. It owns the conversation during one task, records every
assistant/tool turn, limits model turns/batch size/message bytes, and prevents
reused tool call ids. Agent#run_loop leaves the older APIs opt-in and independent.
The fixed model/final schema respect Agent default_model/default_schema unless
overridden. Loading a skill cannot change either.

A final answer optionally passes kernel JSON Schema validation and a separate
verifier callback. Rejections append bounded feedback to the same conversation
and consume turns; the configured rejection allowance withholds an unsuccessful
answer. Outcome reports content only when answered, parsed JSON when applicable,
stop reason, usage, loaded/exposed names, tool evidence refs, transcript digest
and budget snapshot. Answered means the configured checks passed, not proof of
semantic correctness; use task evaluators and independent domain verification.

## Delegation, scope and budget

AgentTool exposes an Agent subclass's run_loop through a closed structured result:
answer/status/evidence_refs/unresolved/usage. Its legacy #call is not invoked.
Children carry tenant/account/principal and intersect parent/local policies and
authorizers. Runtime Context.loop_state is excluded from serialization. Delegation
is serial and depth bounded; the parent retains the user-facing conversation.

ExecutionBudget uses a mutex around admission and usage, tracks one root limit
and per-subtree counters, and charges children into their ancestors exactly once.
Defaults: 20 model-call admissions, 100k total tokens, USD1 estimated cost. Local
loops retain a 20-turn cap even with a larger explicit shared budget. Children
cannot replace the inherited budget; an external charge-only budget can be
wrapped at the root.

Calls are admitted before request and measured usage is charged after response,
before tools/finalization. Cached input counts toward tokens and standard-rate
cost estimates. Already in-flight requests may exceed remaining token/cost
capacity; exhaustion prevents later steps. These are admission/exhaustion limits,
not prepaid token reservations or invoice reconciliation. Unknown usage and
unpriced models are explicit; cost-limited runs require pricing.

Nested legacy completions and schema repairs share admission and usage. Each
received response is charged once before parsing, and typed BudgetExceeded is
preserved. Legacy complete(tools: ...) is denied under ExecutionBudget because
the SDK can recursively issue unobserved requests. Custom provider code outside
these ports remains host responsibility.

## Persistence, observability and compatibility

Conversation, catalogs, callbacks and budget live in-process for one task.
Snapshot is diagnostic; no durable loop resume, distributed budget CAS, streaming
or automatic model migration is introduced. Flow/Active Job remain separate
durable units and governed evaluation probes can run this loop as their executor.

Events: llm.turn, agent_loop.skill_loaded, agent_loop.tools_discovered and
agent_loop.completed. Audit retains digests, names, status and usage, not loop
message bodies, tool arguments/results or reasoning. Host-controlled legacy
logging and provider debug logging keep their own policies.

No migration or runtime dependency. Development/test adds real RubyLLM/WebMock.
Kernel code works with Fake without either gem. Existing non-loop APIs remain
available; Context's serialized representation excludes added runtime state.

## Verification

Behavioral tests cover lazy/cached loading, next-turn schema visibility, policy
intersection/revocation, hidden skills, direct effect denial, byte/batch/token/
call/cost bounds, parallel ordering, typed error recovery, rejected/structured
answers, delegation depth and exact subtree accounting. Real-SDK HTTP contracts
cover OpenAI-compatible and Anthropic wire formats, signed/redacted blocks,
cached tokens and isolated credentials without paid calls. PostgreSQL tests
cover redacted tenant audit and actual loop execution within GovernedStudy's
architecture/holdout/human-review gate.
