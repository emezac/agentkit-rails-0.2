# Rails returns reference application

A headless Rails application showing business-owned approval, verified evidence,
a transactional outbox, an idempotent simulated payment gateway, recovery and
measured outcomes. No LLM, payment credentials or external network calls are
needed. It is a reference implementation, not a production payment service.

## Run from this repository

Use a dedicated PostgreSQL database, never your production database:

```sh
cd examples/returns_app
export RETURNS_DATABASE_URL=postgresql://localhost/agentkit_returns_reference
bundle install
bundle exec rake db:create
bundle exec rake reference:prepare
bundle exec rake reference:demo
```

The demo creates a distinct tenant per invocation. It requests and approves a
500-cent refund, reserves delivery, simulates a lost worker, reconciles the
expired lease, delivers once, and records a mature outcome with an explicitly
virtual clock. Rows are retained for inspection. It sends no money and starts
no automatic recurring jobs. Use a real UTC clock outside this fixture.
`reference:prepare` runs this repository's engine migrations and the application
migration directly; it does not copy generated migration files into the example.

Run the integration scenarios from the repository root:

```sh
bundle exec rspec spec/integration/returns_reference_spec.rb
```

## State and ownership

| Step | Rails application | AgentKit |
| --- | --- | --- |
| Request | Authenticated tenant/account/principal and bounded integer money | Context identity contract |
| Approve | Independent reviewer, exact amount/currency fingerprint | No implied permission from model text |
| Enqueue | Insert an intent and change the request in one transaction | Source row lock, current evidence, DecisionGate proof and idempotent Journal receipt |
| Deliver | Committed lease, provider call outside transaction, response validation | No external call inside the gate |
| Recover | Unknown state, provider lookup, same idempotency key | The decision receipt remains unchanged |
| Learn | Confirmed provider record, source version, final mature metric | BusinessLearning observation/outcome; missing is not success |

`Request`: requested → approved → queued → refunded.

`Intent`: pending → sending → confirmed; an exception or expired lease leads
to unknown. Only reconciliation may recover an uncertain intent. A provider
lookup exception preserves uncertainty. Authoritative absence allows another
attempt with the **same provider key**. A matching confirmation finishes without
another refund. Provider idempotency must remain valid throughout the retry
window; an eventually consistent lookup must not report uncertainty as absence.

The sample allows one refund per request, MXN only, at most 100,000 cents. It does
not model order/payment eligibility, partial refunds or cancellation races.
Replace that domain policy before adopting it. The approval fingerprint binds
the request ID, scope, requester, amount and currency; changes invalidate approval.
Do not grant arbitrary writes to these tables to the model.

## Workers and authorization

Inject `authorize(action, context)` from host policy. Unknown actions must fail
closed. Resolve identities from authentication or a trusted worker registry;
the demo's literal principals are fixtures, not authentication. The source,
Journal and outbox must use the same database pool. Policies are rechecked on
replay. The worker cannot run inside an outer transaction.

`RefundDeliveryJob` has trusted `workflow_factory` and `context_resolver` ports.
Configure them in host boot code; the resolver must return the current authorized
worker context for the exact tenant/account. Schedule jobs only after enqueue's
outer transaction commits. Poll pending intents as well, so a lost job enqueue
does not lose the committed intent. Filter polling by authorized scope and use
`delivery_queue` to route standard/specialist queues. `claim` serializes admission.

Schedule expiry detection/reconciliation separately. Never blindly retry an
unknown payment. Configure real provider timeouts, credential isolation, current
authorization, retention/redaction and human escalation. The default async job
adapter is for local demonstration; use your durable queue in production.

## Controlled experiment

`workflow.pilot(starts_at:, enrollment_ends_at:, analysis_at:)` builds a bounded
BusinessExperiment comparing standard vs specialist routing. Register it before
enrollment and have an independent principal approve it. Both arms require the
same refund policy and gate: a routing experiment cannot relax approval.

For each approved request:

```ruby
pilot.assign(unit_id: request.id.to_s, context: operator_context)
workflow.enqueue_pilot(id: request.id, pilot: pilot, context: operator_context)
```

This persists the chosen `delivery_queue` and the exact experiment execution
receipt together with the intent. The application must actually route each
queue to its intended handlers and measure `handling_seconds` from an independent
host clock. Merely assigning different labels is not evidence of treatment fidelity.
Use `pilot.outcome`, `analyze` and `review_result` at their declared horizons.
There is no automatic adoption. The integration scenario has one unit and must
report insufficient evidence; it deliberately cannot demonstrate improvement.

`workflow.record_outcome` separately measures confirmed refund cents, with
idempotent retries and a minimum 60-second observation window. Lower refund cost
alone is not business success. A real study must also measure customer harm,
correctness and service quality, using application-approved metric contracts.
Use `learning.evaluate` over explicit temporal cohorts and `propose`/independent
`review` to prepare changes; retrospective reports do not prove causality.
