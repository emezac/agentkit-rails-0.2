# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Rails evidence and decision gates", :integration do
  let(:account) { Account.create!(name: "Knowledge", plan: "pro") }
  let(:principal) { Agentkit::Principal.new(id: "requester:1", tenant_key: account.tenant_key, permissions: ["widgets.write"]) }
  let(:context) { Agentkit::Context.new(account: account, principal: principal) }
  let(:widget) { account.widgets.create!(name: "Order", status: "ready") }
  let(:journal) { Agentkit::Knowledge::Journal.new(authorize: ->(_kind, _ctx) { true }) }
  let(:k) { Agentkit::Knowledge }

  def build_gate(version: "1", permission: ->(_args, _ctx) { true }, resolver: nil, limits: {}, source_authorize: ->(_record, _ctx) { true })
    ontology = k::Ontology.new(name: "Widgets", version: "1", entities: ["Widget"],
                              relations: { "Ready" => ["Widget"], "Allowed" => ["Widget"] })
    x = k.var("x")
    rule = k::Rule.new(id: "allow_ready", version: "1", approved_by: "reviewer:1", approved_at: "2020-01-01T00:00:00Z",
                      head: k::Atom.new(relation: "Allowed", terms: [x]), body: [k::Atom.new(relation: "Ready", terms: [x])])
    source = k::ActiveRecordSource.new(name: "widgets", version: "1", ontology: ontology, rules: [rule],
      relation: ->(ctx) { Widget.where(account_id: ctx.account.id) }, authorize: source_authorize,
      extract: lambda do |row, ctx, at|
        next [] unless row.status == "ready"
        [k::Assertion.new(id: "widget:#{row.id}:ready", scope: k::Boundary.scope(ctx), relation: "Ready",
          values: ["widget:#{row.id}"], source: "widgets/#{row.id}", source_version: row.updated_at.utc.iso8601(6),
          observed_at: at, valid_from: at)]
      end)
    k::DecisionGate.new(name: "widget_gate", version: version, source: source, journal: journal,
      queries: ->(args, _ctx) { [{ "relation" => "Allowed", "values" => ["widget:#{args.fetch('id')}"] }] },
      authorize: permission, execution_context: resolver || ->(_proposal) { context }, limits: limits)
  end

  def register_capability(gate, &executor)
    Agentkit::Capability.register(:consume_widget) do |cap|
      cap.input_schema type: "object", properties: { id: { type: "integer" } }, required: ["id"], additionalProperties: false
      cap.required_permission "widgets.write"
      cap.risk :irreversible
      cap.effect :internal
      cap.idempotency :required
      cap.knowledge_gate gate
      cap.executor(&executor)
    end
  end

  it "persists and reloads checked snapshots and idempotent decisions" do
    gate = build_gate
    verdict = gate.check(arguments: { id: widget.id }, context: context, event_id: "request-1")
    expect(verdict.fetch("accepted")).to be(true)
    replay = gate.check(arguments: { id: widget.id }, context: context, event_id: "request-1")
    expect(replay).to eq(verdict)
    expect(Agentkit::KnowledgeEntryRecord.where(kind: "decision").count).to eq(1)
    reloaded = k::Journal.new(authorize: ->(*) { true }).load_snapshot(verdict.fetch("snapshot_digest"), context: context)
    expect(k::Engine.new.run(reloaded).query("Allowed", "widget:#{widget.id}")["status"]).to eq("entailed")
    expect { gate.check(arguments: { id: widget.id, extra: 1 }, context: context, event_id: "request-1") }.to raise_error(k::IntegrityError)
  end

  it "isolates accounts, tenants, principals and rejects corrupted stored evidence" do
    gate = build_gate
    verdict = gate.check(arguments: { id: widget.id }, context: context)
    other = Account.create!(name: "Other")
    other_ctx = Agentkit::Context.new(account: other, principal: "reader")
    expect(journal.load_snapshot(verdict["snapshot_digest"], context: other_ctx)).to be_nil
    same_tenant_other_account = Agentkit::Context.new(tenant_key: account.tenant_key, account: other, principal: "reader")
    expect(journal.load_snapshot(verdict["snapshot_digest"], context: same_tenant_other_account)).to be_nil
    wrong_principal = Agentkit::Context.new(account: account, principal: Agentkit::Principal.new(id: "bad", tenant_key: other.tenant_key))
    expect { gate.check(arguments: { id: widget.id }, context: wrong_principal) }.to raise_error(k::AccessDenied)
    expect { gate.check(arguments: { id: widget.id }, context: other_ctx) }.to raise_error(ActiveRecord::RecordNotFound)
    row = Agentkit::KnowledgeEntryRecord.find_by!(kind: "snapshot")
    row.update!(payload: {})
    expect { journal.load_snapshot(verdict["snapshot_digest"], context: context) }.to raise_error(k::IntegrityError)
  end

  it "requires explicit journal, source and decision authorization" do
    denied_journal = k::Journal.new(authorize: ->(*) { false })
    expect { denied_journal.record_event(id: "event", payload: {}, context: context) }.to raise_error(k::AccessDenied)
    expect { journal.record_event(id: "event", payload: {}, context: Agentkit::Context.new) }.to raise_error(k::AccessDenied)
    expect { build_gate(permission: ->(*) { "yes" }).check(arguments: { id: widget.id }, context: context) }.to raise_error(k::AccessDenied)
    expect { build_gate(source_authorize: ->(*) { false }).check(arguments: { id: widget.id }, context: context) }.to raise_error(k::AccessDenied)
  end

  it "blocks unsupported and incomplete decisions without executing effects" do
    widget.update!(status: "cancelled")
    gate = build_gate
    expect do
      gate.execute(arguments: { id: widget.id }, context: context, operation: "consume", idempotency_key: "deny") { raise "must not run" }
    end.to raise_error(k::DecisionDenied)
    stored = journal.read(kind: "execution", key: "consume:deny", context: context)
    expect(stored["status"]).to eq("blocked")
    expect(stored["verdict"]["checks"].first["status"]).to eq("not_entailed")
    widget.update!(status: "ready")
    verdict = build_gate(limits: { max_steps: 1 }).check(arguments: { id: widget.id }, context: context)
    expect(verdict["accepted"]).to be(false)
    expect(verdict["closure_complete"]).to be(false)
  end

  it "rolls back effects and receipt on exceptions and permits a clean retry" do
    gate = build_gate
    args = { arguments: { id: widget.id }, context: context, operation: "consume", idempotency_key: "retry" }
    expect do
      gate.execute(**args) { widget.update!(status: "consumed"); raise "worker crashed" }
    end.to raise_error("worker crashed")
    expect(widget.reload.status).to eq("ready")
    expect(journal.read(kind: "execution", key: "consume:retry", context: context)).to be_nil
    output = gate.execute(**args) { widget.update!(status: "consumed"); { done: true } }
    expect(output).to eq("done" => true)
    expect(gate.execute(**args) { raise "duplicate effect" }).to eq(output)
    expect { gate.execute(**args.merge(arguments: { id: widget.id, extra: true })) {} }.to raise_error(k::IntegrityError)
  end

  it "requires current permissions even when replaying successful effects" do
    allowed = true
    gate = build_gate(permission: ->(*) { allowed })
    args = { arguments: { id: widget.id }, context: context, operation: "consume", idempotency_key: "auth" }
    gate.execute(**args) { { done: true } }
    allowed = false
    expect { gate.execute(**args) { raise "must not run" } }.to raise_error(k::AccessDenied)
  end

  it "serializes competing decisions on the same business row", :real_concurrency do
    gate, ctx, id = build_gate, context, widget.id
    outcomes = 2.times.map do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          gate.execute(arguments: { id: id }, context: ctx, operation: "consume", idempotency_key: "race-#{index}") do
            Widget.find(id).update!(status: "consumed")
            { consumed: true }
          end
          :executed
        rescue Agentkit::Knowledge::DecisionDenied
          :blocked
        end
      end
    end.map(&:value)
    expect(outcomes).to contain_exactly(:executed, :blocked)
    expect(Agentkit::KnowledgeEntryRecord.where(kind: "execution").count).to eq(2)
  end

  it "deduplicates concurrent effects sharing an idempotency key", :real_concurrency do
    gate, ctx, id = build_gate, context, widget.id
    effects = Queue.new
    results = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          gate.execute(arguments: { id: id }, context: ctx, operation: "consume", idempotency_key: "same") do
            effects << :effect
            Widget.find(id).update!(status: "consumed")
            { consumed: true }
          end
        end
      end
    end.map(&:value)
    expect(results.uniq).to eq([{ "consumed" => true }])
    expect(effects.size).to eq(1)
  end

  it "recovers durable events with idempotent same-database processing" do
    journal.record_event(id: "order-updated", payload: { id: widget.id }, context: context)
    journal.record_event(id: "order-updated", payload: { id: widget.id }, context: context)
    expect { journal.record_event(id: "order-updated", payload: { id: -1 }, context: context) }.to raise_error(k::IntegrityError)
    expect do
      journal.consume_event(id: "order-updated", context: context) do |_event|
        widget.update!(status: "consumed")
        raise "crash"
      end
    end.to raise_error("crash")
    expect(widget.reload.status).to eq("ready")
    expect(journal.pending_event_ids(context: context)).to eq(["order-updated"])
    other_worker = k::Journal.new(authorize: ->(*) { true })
    other_worker.consume_event(id: "order-updated", context: context) { |event| Widget.find(event.fetch("id")).update!(status: "consumed") }
    other_worker.consume_event(id: "order-updated", context: context) { raise "duplicate" }
    expect(other_worker.pending_event_ids(context: context)).to eq([])
    expect(widget.reload.status).to eq("consumed")
  end

  it "rejects injected claims and additional unverified prose in final answers" do
    gate = build_gate
    verifier = k::AnswerVerifier.new(gate: gate, arguments: { id: widget.id })
    claims = gate.claims({ id: widget.id }, context)
    expect(verifier.call({ "answer" => JSON.generate("claims" => claims) }, context)[:accepted]).to be(true)
    expect(verifier.call({ "answer" => { "claims" => claims, "text" => "refund completed" } }, context)[:accepted]).to be(false)
    expect(verifier.call({ "answer" => { "claims" => [{ "relation" => "Allowed", "values" => ["widget:other"] }] } }, context)[:accepted]).to be(false)
    widget.update!(status: "cancelled")
    expect(verifier.call({ "answer" => JSON.generate("claims" => claims) }, context)[:accepted]).to be(false)
  end

  it "gates read-only tools through their precondition adapter" do
    gate = build_gate
    calls = 0
    tool = Agentkit::ToolContract.new(name: :ready_widget, params: { id: :integer },
      preconditions: gate.precondition, callable: ->(id:) { calls += 1; { id: id } })
    tool.invoke({ id: widget.id }, context: context)
    widget.update!(status: "cancelled")
    expect { tool.invoke({ id: widget.id }, context: context) }.to raise_error(Agentkit::ToolPreconditionFailed)
    expect(calls).to eq(1)
  end

  it "rechecks approved Actions against current business state" do
    gate = build_gate
    register_capability(gate) { |args| Widget.find(args[:id]).update!(status: "consumed"); { consumed: true } }
    invocation = Agentkit::Actions.invoke(capability: :consume_widget, arguments: { id: widget.id }, principal: principal,
                                          idempotency_key: "action-1", context: context)
    widget.update!(status: "cancelled")
    approver = Agentkit::Principal.new(id: "reviewer:2", tenant_key: account.tenant_key, permissions: ["widgets.write"])
    result = Agentkit::Actions.decide!(invocation[:proposal].id, decision: :approved, actor: approver, scope: { tenant_key: account.tenant_key })
    expect(result.status).to eq("execution_failed")
    expect(widget.reload.status).to eq("cancelled")
  end

  it "executes gated approved Actions under the reauthenticated requester" do
    seen = nil
    register_capability(build_gate) do |args, context:|
      seen = context.principal.id
      Widget.find(args[:id]).update!(status: "consumed")
      { consumed: true }
    end
    invocation = Agentkit::Actions.invoke(capability: :consume_widget, arguments: { id: widget.id }, principal: principal,
                                          idempotency_key: "action-2", context: context)
    approver = Agentkit::Principal.new(id: "reviewer:2", tenant_key: account.tenant_key, permissions: ["widgets.write"])
    result = Agentkit::Actions.decide!(invocation[:proposal].id, decision: :approved, actor: approver, scope: { tenant_key: account.tenant_key })
    expect(result.status).to eq("executed"), Agentkit::ExecutionAttemptRecord.find_by!(proposal_id: result.id).error_code.to_s
    expect(seen).to eq(principal.id)
    expect(widget.reload.status).to eq("consumed")
  end

  it "rejects gate version drift and removal after approval" do
    register_capability(build_gate) { |_args| raise "must not run" }
    invocation = Agentkit::Actions.invoke(capability: :consume_widget, arguments: { id: widget.id }, principal: principal,
                                          idempotency_key: "drift", context: context)
    register_capability(build_gate(version: "2")) { |_args| raise "must not run" }
    expect do
      Agentkit::Actions.propose!(capability: :consume_widget, arguments: { id: widget.id }, requester: principal,
                                idempotency_key: "drift", context: context)
    end.to raise_error(Agentkit::IdempotencyConflict)
    approver = Agentkit::Principal.new(id: "reviewer:2", tenant_key: account.tenant_key, permissions: ["widgets.write"])
    result = Agentkit::Actions.decide!(invocation[:proposal].id, decision: :approved, actor: approver, scope: { tenant_key: account.tenant_key })
    expect(result.status).to eq("execution_failed")
    expect(Agentkit::ExecutionAttemptRecord.find_by!(proposal_id: result.id).error_code).to eq("Agentkit::Knowledge::IntegrityError")
  end

  it "refuses external/async gated capabilities and rolls back invalid output" do
    cap = register_capability(build_gate) { |args| Widget.find(args[:id]).update!(status: "consumed"); { wrong: true } }
    cap.output_schema type: "object", properties: { done: { type: "boolean" } }, required: ["done"], additionalProperties: false
    expect { cap.execute({ id: widget.id }, context: context, idempotency_key: "invalid-output") }.to raise_error(Agentkit::SchemaValidationError)
    expect(widget.reload.status).to eq("ready")
    cap.effect :external
    expect { cap.execute({ id: widget.id }, context: context, idempotency_key: "external") }.to raise_error(Agentkit::ConfigurationError)
  end

  it "refuses gate removal and revoked requester permissions on workers" do
    revoked = false
    resolver = lambda do |_proposal|
      actor = Agentkit::Principal.new(id: principal.id, tenant_key: account.tenant_key,
                                     permissions: revoked ? [] : ["widgets.write"])
      Agentkit::Context.new(account: account, principal: actor)
    end
    register_capability(build_gate(resolver: resolver)) { |_args| raise "must not execute" }
    invocation = Agentkit::Actions.invoke(capability: :consume_widget, arguments: { id: widget.id }, principal: principal,
                                          idempotency_key: "revoked", context: context)
    revoked = true
    approver = Agentkit::Principal.new(id: "reviewer:2", tenant_key: account.tenant_key, permissions: ["widgets.write"])
    result = Agentkit::Actions.decide!(invocation[:proposal].id, decision: :approved, actor: approver, scope: { tenant_key: account.tenant_key })
    expect(result.status).to eq("execution_failed")
    expect(Agentkit::ExecutionAttemptRecord.find_by!(proposal_id: result.id).error_code).to eq("Agentkit::Knowledge::AccessDenied")
    invocation = Agentkit::Actions.invoke(capability: :consume_widget, arguments: { id: widget.id }, principal: principal,
                                          idempotency_key: "removed", context: context)
    Agentkit::Capability.register(:consume_widget) { |cap| cap.executor { raise "ungated execution" } }
    result = Agentkit::Actions.decide!(invocation[:proposal].id, decision: :approved, actor: approver, scope: { tenant_key: account.tenant_key })
    expect(Agentkit::ExecutionAttemptRecord.find_by!(proposal_id: result.id).error_code).to eq("Agentkit::Knowledge::IntegrityError")
  end

  it "rejects a different execution principal and a separate source database" do
    gate = build_gate(resolver: ->(_proposal) { Agentkit::Context.new(account: account, principal: "system:executor") })
    proposal = Agentkit::Actions::Proposal.new(tenant_key: account.tenant_key, requester_principal_id: principal.id)
    expect { gate.context_for(proposal) }.to raise_error(k::AccessDenied)
    allow(Agentkit::KnowledgeEntryRecord).to receive(:table_exists?).and_return(true)
    allow(Agentkit::KnowledgeEntryRecord).to receive(:connection_pool).and_return(Object.new)
    expect { gate.check(arguments: { id: widget.id }, context: context) }.to raise_error(k::InvalidContract, /connection pool/)
  end

  it "uses the real AgentLoop verifier boundary and withholds unsupported final answers" do
    gate = build_gate
    verifier = k::AnswerVerifier.new(gate: gate, arguments: { id: widget.id })
    answer = JSON.generate("claims" => gate.claims({ id: widget.id }, context))
    Agentkit::LLM::Pricing.register("knowledge-test", input: 1, output: 1)
    Agentkit::LLM::Adapters::Fake.respond_with_turns(content: answer)
    result = Agentkit::Agent.new(context: context).run_loop("check eligibility", model: "knowledge-test", verifier: verifier)
    expect(result).to be_answered
    widget.update!(status: "cancelled")
    Agentkit::LLM::Adapters::Fake.respond_with_turns({ content: answer }, { content: answer })
    result = Agentkit::Agent.new(context: context).run_loop("check eligibility", model: "knowledge-test", verifier: verifier)
    expect(result.stop_reason).to eq("verification_failed")
    expect(result.content).to be_nil
  end

  it "loads the documented Rails adapter factory against a real application model" do
    require_relative "../../examples/rails_evidence"
    gate = RailsEvidenceExample.build(model: Widget, authorize_record: ->(*) { true },
      authorize_decision: ->(*) { true }, authorize_journal: ->(*) { true },
      execution_context: ->(_proposal) { context }, approved_by: "reviewer:1", approved_at: "2020-01-01T00:00:00Z")
    expect(gate.check(arguments: { id: widget.id }, context: context)["accepted"]).to be(true)
    widget.update!(status: "cancelled")
    expect(gate.check(arguments: { id: widget.id }, context: context)["accepted"]).to be(false)
  end

  it "reauthorizes a decision after acquiring the business lock" do
    checks = 0
    gate = build_gate(permission: ->(*) { checks += 1; checks == 1 })
    expect do
      gate.execute(arguments: { id: widget.id }, context: context, operation: "consume", idempotency_key: "recheck") { raise "must not execute" }
    end.to raise_error(k::AccessDenied)
    expect(checks).to eq(2)
  end

  it "recovers a committed effect when Actions finalization fails without repeating it" do
    effects = 0
    register_capability(build_gate) do |args|
      effects += 1
      Widget.find(args[:id]).update!(status: "consumed")
      { consumed: true }
    end
    fail_finalization = true
    allow(Agentkit::Audit).to receive(:record).and_wrap_original do |original, **options|
      if options[:event_type] == "action.execution.finished" && fail_finalization
        fail_finalization = false
        raise IOError, "audit temporarily unavailable"
      end
      original.call(**options)
    end
    invocation = Agentkit::Actions.invoke(capability: :consume_widget, arguments: { id: widget.id }, principal: principal,
                                          idempotency_key: "finalization-retry", context: context)
    approver = Agentkit::Principal.new(id: "reviewer:2", tenant_key: account.tenant_key, permissions: ["widgets.write"])
    result = Agentkit::Actions.decide!(invocation[:proposal].id, decision: :approved, actor: approver, scope: { tenant_key: account.tenant_key })
    expect(result.status).to eq("execution_failed")
    expect(widget.reload.status).to eq("consumed")
    retried = Agentkit::Actions.execute!(result.id, scope: { tenant_key: account.tenant_key }, retry_failed: true)
    expect(retried.status).to eq("executed")
    expect(effects).to eq(1)
  end
end
