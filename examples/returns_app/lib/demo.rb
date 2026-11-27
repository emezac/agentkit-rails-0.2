# frozen_string_literal: true
require_relative "returns_reference"

module ReturnsReference
  def self.demo
    # Fixtures only: production policies must resolve authenticated identities.
    roles = { "request" => ["customer"], "approve" => ["reviewer"],
      "enqueue" => ["worker"], "deliver" => ["worker"], "reconcile" => ["worker"],
      "learning" => ["worker"], "journal" => ["worker"] }
    policy = ->(action, ctx) { roles.fetch(action, []).include?(ctx.principal) }
    tenant = "demo-#{SecureRandom.uuid}"
    context = ->(actor) { Agentkit::Context.new(tenant_key: tenant, account: 1, principal: actor) }
    clock = { now: Time.now.utc }
    workflow = Workflow.new(authorize: policy, clock: -> { clock[:now] })
    request = workflow.request(amount_cents: 500, context: context.call("customer"))
    workflow.approve(id: request.id, context: context.call("reviewer"))
    intent = workflow.enqueue(id: request.id, context: context.call("worker")).fetch("intent_id")
    # Simulate a process dying after admission but before sending to the provider.
    workflow.claim(id: intent, context: context.call("worker"))
    clock[:now] += 61
    restarted = Workflow.new(authorize: policy, clock: -> { clock[:now] })
    restarted.reconcile(id: intent, context: context.call("worker"))
    restarted.deliver(id: intent, context: context.call("worker"))
    clock[:now] += 60 # virtual clock for the demo's observation window only
    outcome = restarted.record_outcome(id: intent, context: context.call("worker"))
    puts JSON.pretty_generate(tenant: tenant, request_id: request.id, intent_id: intent,
      status: request.reload.status, outcome: outcome, simulated: true)
  end
end
