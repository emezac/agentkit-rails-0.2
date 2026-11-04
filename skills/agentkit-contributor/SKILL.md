---
name: agentkit-contributor
description: Guide scoped source and test changes in the AgentKit Rails repository with focused behavior checks and its existing full verification suite. Use when contributing to AgentKit itself.
---

# Contribute to AgentKit Rails

Use this repository skill for changes to the gem or its Rails engine. It is a developer workflow; do not load it as a runtime skill for application agents.

1. Identify the public behavior or failure being changed. For a bug, reproduce it in a spec that calls the affected API. Keep the change local and remove obsolete branches when a simpler invariant replaces them.
2. Review the changed boundary that matters: tenant and principal scope for data, authorization for tools and skills, durable idempotency and reconciliation for external effects, and token or model-call budgets for agent loops. Check only the boundaries touched by the change.
3. Choose specs that exercise the user-visible behavior, including a retry, failure, or cross-tenant case when relevant. Run the focused gate against the current diff:

   ```bash
   BASE=HEAD SPEC='spec/lib/agent_loop_spec.rb spec/integration/agent_loop_spec.rb' bundle exec rake quality:focused
   ```

   Set `BASE` to the branch or commit under review if the change is already committed. The gate checks diff whitespace, syntax of changed Ruby files, and the explicitly selected specs. It requires `SPEC` when Ruby files changed so a syntax-only result cannot be mistaken for behavioral verification. Select specs by behavior; filename matching alone is insufficient for cross-cutting changes.
4. Run `bundle exec rake verify` for broad changes, release preparation, or when the focused specs do not cover the affected behavior. Report the verified behavior and any remaining limitation. Commit or push only when the task authorizes it.

Inspired by [ub-mode](https://github.com/unclebob/ub-mode); its Crapper, Dryer, and Mutator tools do not currently cover Ruby, so this workflow uses the repository's existing Ruby checks.
