# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Production Operations Evidence", :integration do
  let(:ops) { Agentkit::Operations }
  let(:k) { Agentkit::Knowledge }
  let(:account) { Account.create!(name: "Operations", plan: "pro") }
  let(:context) { Agentkit::Context.new(account: account, principal: "monitor") }
  let(:human) { Agentkit::Context.new(account: account, principal: "human") }
  let(:base) { Time.now.utc }
  let(:clock) { { now: base } }
  let(:authorize) { ->(action, ctx) { action != "acknowledge" || ctx.principal == "human" } }
  let(:journal_policy) { { rollback: false } }
  let(:journal) { k::Journal.new(authorize: ->(*) { raise ActiveRecord::Rollback if journal_policy[:rollback]; true }) }
  let(:services) do
    { "checkout" => { "owner" => "ops-manager", "on_call" => "checkout-primary", "dependencies" => [],
      "runbooks" => [{ "reference" => "runbook/checkout", "version" => "git:42" }],
      "slo" => { "availability_basis_points" => 9990 }, "sources" => { "observability" => 300, "deployments" => 300 } } }
  end
  let(:catalog) { ops::Catalog.new(name: "shop", version: "1", services: services) }
  let(:deployment) do
    { "kind" => "deployment", "at" => (base - 3600).iso8601(6), "reference" => "deploy/100", "version" => "1",
      "data" => { "repository" => "repo/shop", "base_sha" => "a" * 40, "deployed_sha" => "b" * 40,
        "diff_reference" => "diff/100", "diff" => "+ changed code", "diff_digest" => Digest::SHA256.hexdigest("+ changed code"),
        "service" => "checkout", "environment" => "production" } }
  end
  let(:loader) do
    ->(request, ctx) do
      { scope: k::Boundary.scope(ctx), status: "ok", observed_at: base.iso8601(6),
        items: request["source"] == "deployments" ? [deployment] : [] }
    end
  end
  let(:options) { { catalog: catalog, journal: journal, authorize: authorize, loader: loader, verifier: ->(*) { { accepted: true, reasons: [] } }, verifier_version: "review-policy:1", clock: -> { clock[:now] }, ack_timeout: 120 } }
  let(:monitor) { ops::Monitor.new(**options) }
  let(:capture_args) { { id: "incident-1", service: "checkout", environment: "production", from: (base - 60).iso8601(6), to: base.iso8601(6), context: context } }

  def recommendation(incident)
    refs = incident.fetch("evidence").map { |e| e.fetch("id") }
    { id: "recommendation-1", incident_id: "incident-1", context: context,
      observations: [{ text: "Deployed revision changed", evidence_ids: refs }],
      hypotheses: [{ text: "Change may contribute", supporting_ids: refs, opposing_ids: [] }],
      checks: [{ text: "Inspect trace", evidence_ids: refs, read_only: true }],
      proposed_fix: { description: "Consider rollback", risk: "high", preconditions: ["human approval"], rollback: "restore reviewed release" } }
  end

  it "binds catalog, deployment diff and source coverage without treating empty results as an outage" do
    dossier = monitor.capture(**capture_args)
    expect(dossier["status"]).to eq("observed")
    expect(dossier.dig("coverage", "observability", "count")).to eq(0)
    expect(dossier["catalog_digest"]).to eq(catalog.digest)
    expect(dossier["evidence"].first.dig("data", "deployed_sha")).to eq("b" * 40)
    expect(dossier["authorizes"]).to be(false)
    expect(monitor.capture(**capture_args)).to eq(dossier)
    expect { monitor.capture(**capture_args.merge(environment: "staging")) }.to raise_error(k::IntegrityError)
  end

  it "rejects unknown catalog dependencies and non-versioned runbooks" do
    services["checkout"]["dependencies"] = ["unknown"]
    expect { catalog }.to raise_error(k::InvalidContract)
  end

  it "persists unavailable evidence and its escalation atomically without leaking exception messages" do
    broken = ops::Monitor.new(**options.merge(loader: ->(*) { raise "secret token" }))
    dossier = broken.capture(**capture_args)
    escalation = broken.escalations.fetch(id: "incident:incident-1", context: context)
    expect(dossier["status"]).to eq("needs_help")
    expect(escalation["incident_digest"]).to eq(k.digest(dossier))
    expect(JSON.generate(dossier)).not_to include("secret token")
    expect(escalation["status"]).to eq("open")
    expect(broken.capture(**capture_args)).to eq(dossier)
  end

  it "rolls back the dossier if the escalation cannot be persisted" do
    broken = ops::Monitor.new(**options.merge(loader: ->(*) { raise "outage" }))
    allow(broken.escalations).to receive(:enqueue).and_raise("storage down")
    expect { broken.capture(**capture_args) }.to raise_error("storage down")
    expect(broken.fetch(type: "incident", id: "incident-1", context: context)).to be_nil
  end

  it "fails closed for cross-scope evidence rather than recording it" do
    bad = ops::Monitor.new(**options.merge(loader: ->(*) { { scope: "other", status: "ok", observed_at: base.iso8601, items: [] } }))
    expect { bad.capture(**capture_args) }.to raise_error(k::AccessDenied)
    expect(bad.fetch(type: "incident", id: "incident-1", context: context)).to be_nil
  end

  it "isolates tenant reads and rejects access-denied operations" do
    monitor.capture(**capture_args)
    other = Agentkit::Context.new(account: Account.create!(name: "Other"), principal: "monitor")
    expect(monitor.fetch(type: "incident", id: "incident-1", context: other)).to be_nil
    denied = ops::Monitor.new(**options.merge(authorize: ->(*) { false }))
    expect { denied.capture(**capture_args) }.to raise_error(k::AccessDenied)
  end

  it "escalates stale sources, invalid diff digests and wrong deployed environments" do
    clock[:now] = base + 301
    expect(monitor.capture(**capture_args)["reasons"]).to include("source:deployments:stale")
    clock[:now] = base
    deployment["data"]["diff"] = "tampered"
    expect(monitor.capture(**capture_args.merge(id: "bad-diff"))["status"]).to eq("needs_help")
    deployment["data"]["diff"] = "+ changed code"
    deployment["data"]["environment"] = "staging"
    expect(monitor.capture(**capture_args.merge(id: "bad-env"))["status"]).to eq("needs_help")
  end

  it "verifies references and keeps recommendations distinct from causal proof or action authorization" do
    args = recommendation(monitor.capture(**capture_args))
    result = monitor.recommend(**args)
    expect(result["status"]).to eq("verified_recommendation")
    expect(result.values_at("authorizes", "causal_proof")).to eq([false, false])
    expect(monitor.recommend(**args)).to eq(result)
    changed = ops::Monitor.new(**options.merge(verifier_version: "review-policy:2"))
    expect { changed.recommend(**args) }.to raise_error(k::IntegrityError)
    args[:observations][0][:evidence_ids] = ["invented"]
    expect { monitor.recommend(**args) }.to raise_error(k::InvalidContract)
  end

  it "rejects executable diagnostics and catalog drift" do
    args = recommendation(monitor.capture(**capture_args))
    args[:checks][0][:read_only] = false
    expect { monitor.recommend(**args) }.to raise_error(k::InvalidContract)
    changed = ops::Monitor.new(**options.merge(catalog: ops::Catalog.new(name: "shop", version: "2", services: services)))
    expect { changed.recommend(**args) }.to raise_error(k::IntegrityError)
  end

  it "escalates verifier failures, rejection, and evidence expired before verification" do
    args = recommendation(monitor.capture(**capture_args))
    rejected = ops::Monitor.new(**options.merge(verifier: ->(*) { { accepted: false, reasons: ["not supported"] } }))
    expect(rejected.recommend(**args)["reasons"]).to include("verification_rejected")
    expect(rejected.escalations.fetch(id: "recommendation:recommendation-1", context: context)["status"]).to eq("open")
    failed = ops::Monitor.new(**options.merge(verifier: ->(*) { raise "secret" }))
    expect(failed.recommend(**args.merge(id: "failed"))["reasons"]).to include("verifier_unavailable:RuntimeError")
    clock[:now] = base + 301
    expect(monitor.recommend(**args.merge(id: "expired"))["reasons"]).to include("source:deployments:expired")
  end

  it "does not give replay expectations to the runner or accept automatic execution" do
    report = ops::Replay.evaluate(cases: [{ id: "past", input: { incident: "fixture" }, expected_status: "needs_help", required_evidence_ids: ["e1"] }],
      runner: ->(input) {
        expect(input.keys).to eq(["incident"])
        { status: "needs_help", observations: [{ evidence_ids: ["e1"] }], authorizes: false, causal_proof: false }
      })
    expect(report["passed"]).to eq(1)
    bad = ops::Replay.evaluate(cases: [{ id: "past", input: {}, expected_status: "needs_help", required_evidence_ids: [] }], runner: ->(*) { raise "error" })
    expect(bad["passed"]).to eq(0)
  end

  context "durable escalation delivery", :real_concurrency do
    let(:outbox) { ops::Escalations.new(journal: journal, authorize: authorize, clock: -> { clock[:now] }, ack_timeout: 120, retry_after: 10, lease_seconds: 15, max_attempts: 2) }
    let(:enqueue_args) { { id: "alert", incident_id: "incident", incident_digest: "a" * 64, primary: "primary", fallback: "fallback", reasons: ["source unavailable"], context: context } }

    before { outbox.enqueue(**enqueue_args) }

    it "keeps delivery separate from human acknowledgement and enforces human policy" do
      delivered = outbox.deliver(id: "alert", sender: ->(*) { "receipt" }, context: context)
      expect(delivered["status"]).to eq("open")
      expect(delivered["delivered_at"]).not_to be_nil
      expect { outbox.acknowledge(id: "alert", reason: "seen", context: context) }.to raise_error(k::AccessDenied)
      ack = outbox.acknowledge(id: "alert", reason: "investigating", context: human)
      expect(ack["status"]).to eq("acknowledged")
      expect(outbox.acknowledge(id: "alert", reason: "investigating", context: human)).to eq(ack)
      expect(outbox.due(context: context)).to eq([])
      expect { outbox.acknowledge(id: "alert", reason: "changed", context: human) }.to raise_error(k::IntegrityError)
    end

    it "retries with a stable provider key, escalates to fallback and exposes unacknowledged exhaustion" do
      calls = []
      sender = ->(request, _) { calls << request; raise "outage" }
      outbox.deliver(id: "alert", sender: sender, context: context)
      expect(outbox.due(context: context)).to be_empty
      clock[:now] = base + 10
      expect(outbox.due(context: context).size).to eq(1)
      outbox.deliver(id: "alert", sender: sender, context: context)
      expect(calls.map { |r| r["idempotency_key"] }.uniq.size).to eq(1)
      clock[:now] = base + 120
      result = outbox.deliver(id: "alert", sender: ->(request, _) { calls << request; "receipt" }, context: context)
      expect(result["target_index"]).to eq(1)
      expect(calls.last["target"]).to eq("fallback")
      expect(calls.last["idempotency_key"]).not_to eq(calls.first["idempotency_key"])
      clock[:now] = base + 240
      expect(outbox.deliver(id: "alert", sender: sender, context: context)["status"]).to eq("exhausted")
      expect(outbox.list(status: "exhausted", context: context).map { |row| row["id"] }).to eq(["alert"])
      expect(outbox.acknowledge(id: "alert", reason: "late acknowledgement", context: human)["status"]).to eq("acknowledged")
    end

    it "does not send again after delivery or restart deadlines when enqueued again" do
      original = outbox.fetch(id: "alert", context: context)
      outbox.deliver(id: "alert", sender: ->(*) { "receipt" }, context: context)
      clock[:now] = base + 30
      expect(outbox.enqueue(**enqueue_args)["ack_due_at"]).to eq(original["ack_due_at"])
      outbox.deliver(id: "alert", sender: ->(*) { raise "should not run" }, context: context)
      expect(outbox.fetch(id: "alert", context: context)["attempts"]).to eq(1)
      expect { outbox.enqueue(**enqueue_args.merge(fallback: "changed")) }.to raise_error(k::IntegrityError)
    end

    it "reclaims expired leases after crashes and blocks cross-tenant delivery" do
      Agentkit::OperationsEscalationRecord.first.update!(lease_token: "crashed", lease_until: base + 15, attempts: 1)
      expect(outbox.due(context: context)).to be_empty
      clock[:now] = base + 16
      expect(outbox.deliver(id: "alert", sender: ->(*) { "recovered" }, context: context)["attempts"]).to eq(2)
      other = Agentkit::Context.new(account: Account.create!(name: "Other"), principal: "monitor")
      expect(outbox.fetch(id: "alert", context: other)).to be_nil
      expect { outbox.deliver(id: "alert", sender: ->(*) { "bad" }, context: other) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "rejects caller-owned transactions before contacting a provider" do
      ActiveRecord::Base.transaction do
        expect { outbox.deliver(id: "alert", sender: ->(*) { "bad" }, context: context) }.to raise_error(k::InvalidContract, /outside a transaction/)
      end
    end

    it "does not notify when the claim audit rolls back and detects payload corruption" do
      journal_policy[:rollback] = true
      sender = spy("provider")
      expect { outbox.deliver(id: "alert", sender: sender, context: context) }.to raise_error(k::IntegrityError, /rolled back/)
      expect(sender).not_to have_received(:call)
      row = Agentkit::OperationsEscalationRecord.first
      expect(row.attempts).to eq(0)
      row.update!(payload: row.payload.merge("targets" => ["attacker", "attacker"]))
      expect { outbox.fetch(id: "alert", context: context) }.to raise_error(k::IntegrityError)
    end

    it "uses leases across workers and permits acknowledgement during provider IO" do
      started, release = Queue.new, Queue.new
      worker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          outbox.deliver(id: "alert", sender: ->(*) { started << true; release.pop; "receipt" }, context: context)
        end
      end
      begin
        Timeout.timeout(10) { started.pop }
        count = 0
        outbox.deliver(id: "alert", sender: ->(*) { count += 1; "duplicate" }, context: context)
        expect(count).to eq(0)
        outbox.acknowledge(id: "alert", reason: "working", context: human)
      ensure
        release << true
        worker.value
      end
      expect(outbox.fetch(id: "alert", context: context)["status"]).to eq("acknowledged")
    end
  end
end
