# AgentKit memory harness implementation

Scope: AgentKit Rails v1.12, with no additional model calls or required embeddings.

1. Context: compact older completed turns deterministically when the loop reaches its byte limit. Preserve the original request, current tool exchange, evidence digests, and a bounded summary marker. Stop safely if the remaining context still cannot fit.
2. Task notes and episodes: add opt-in `task_id:` continuity to `run_loop`. Save a bounded, tenant-scoped checkpoint after each completed turn and a searchable, keyword-only episode at completion. Do not persist tool bodies or full transcripts. Provide resume/search APIs.
3. Semantic facts: provide explicit user and project fact APIs backed by the existing Memory store, with user/tenant isolation, replacement by key, and keyword retrieval without embedding calls.
4. Procedures: extract from a supplied transcript into a quarantined TeamMemory asset. Require explicit authenticated review before activation. Fix `mem:skill` so it no longer claims to extract a conversation that was never retained.
5. Verification: test compaction, resume, tenant/user isolation, no embedding calls, and procedure quarantine/activation; run the focused AgentKit suite.

All continuity writes are opt-in. The host Rails app chooses task IDs and the material eligible for durable memory; keyword recall avoids vector costs.
