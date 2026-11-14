# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agentkit::Harness::UnattendedRun, :integration, :real_concurrency do
  let(:k) { Agentkit::Knowledge }
  let(:account) { Account.create!(name: "Night shift", plan: "pro") }
  let(:operator) { Agentkit::Context.new(account: account, principal: "operator") }
  let(:worker) { Agentkit::Context.new(account: account, principal: "worker") }
  let(:verifier) { Agentkit::Context.new(account: account, principal: "verifier") }
  let(:base) { Time.now.utc }
  let(:clock) { { now: base } }
  let(:policy) { { rollback: false, worker: true } }
  let(:journal) { k::Journal.new(authorize: ->(*) { raise ActiveRecord::Rollback if policy[:rollback]; true }) }
  let(:authorizer) do
    ->(action, ctx) do
      case action
      when "start", "cancel", "expire" then ctx.principal == "operator"
      when "work" then ctx.principal == "worker" && policy[:worker]
      when "verify" then ctx.principal == "verifier"
      when "read", "read_history" then true
      else false
      end
    end
  end
  let(:outbox) { Agentkit::Operations::Escalations.new(journal: journal, authorize: ->(*) { true }, clock: -> { clock[:now] }) }
  let(:options) { { journal: journal, authorize: authorizer, escalations: outbox, clock: -> { clock[:now] } } }
  subject(:run) { described_class.new(**options) }
  let(:goal) { Agentkit::Harness::Goal.new(id: "fix-price", objective: "Correct checkout price", criteria: [{ id: "tests", description: "independent tests pass" }], protected_resources: ["tests/"], max_steps: 3) }
  let(:gate) { Agentkit::Harness::VerificationGate.new(id: "tests", description: "checkout acceptance") }
  let(:artifact) { { "commit_sha" => "a" * 40, "configuration_digest" => "sha256:#{'b' * 64}", "dependencies_digest" => "sha256:#{'c' * 64}", "protected_digest" => "sha256:#{'d' * 64}", "reference" => "sandbox:artifact-0", "digest" => "sha256:#{'e' * 64}" } }
  let(:limits) { { max_attempts: 3, max_cost_microusd: 1000, max_tokens: 10_000, run_seconds: 600, call_seconds: 60, cost_per_call_microusd: 100, tokens_per_call: 1000, stall_limit: 2 } }
  let(:start_args) { { id: "night", goal: goal, gates: [gate], artifact: artifact, allowed_resources: ["src/"], protected_resources: ["tests/"], executor_version: "isolated-runner:1", limits: limits, primary: "on-call", fallback: "owner", context: operator } }
  let(:usage) { { cost_microusd: 10, tokens: 100 } }
  let(:failures) { [{ gate_id: "tests", code: "price_mismatch", subject: "checkout", expected: "90", actual: "80" }] }

  def claim(role, request_id)
    run.claim(id: "night", role: role, request_id: request_id, context: role == "worker" ? worker : verifier)
  end

  def check(request_id, status: "failed", observed: nil, diagnostics: nil, progress: "sha256:#{'f' * 64}", measured: usage, results: nil)
    lease = claim("verifier", request_id).fetch("lease")
    current = observed || run.fetch(id: "night", context: operator).fetch("artifact")
    data = results || [gate.record(status: status, commit_sha: current["commit_sha"], source: "ci:#{request_id}",
      configuration_digest: current["configuration_digest"], dependencies_digest: current["dependencies_digest"], checked_at: clock[:now], value: { errors: status == "failed" ? 1 : 0 })]
    run.report_verification(id: "night", token: lease.fetch("token"), artifact: current, results: data,
      failures: diagnostics || (status == "failed" ? failures : []), progress_digest: progress, usage: measured, context: verifier)
  end

  def work(request_id, measured: usage, changed: nil, outcome: "completed")
    lease = claim("worker", request_id).fetch("lease")
    current = changed || artifact.merge("commit_sha" => Digest::SHA1.hexdigest(request_id), "reference" => "sandbox:#{request_id}", "digest" => Agentkit::Harness.digest(request_id))
    run.report_work(id: "night", token: lease.fetch("token"), artifact: current, worker_claim: "All tests pass (untrusted worker statement)", usage: measured, outcome: outcome, context: worker)
  end

  before { run.start(**start_args) }

  it "requires independent gates, not a worker saying done, and produces a reviewable receipt" do
    expect(check("baseline").dig("state", "status")).to eq("ready")
    expect(work("work-1").dig("state", "status")).to eq("awaiting_verification")
    expect(check("verify-1", status: "passed").dig("state", "status")).to eq("verified")
    expect(run.fetch(id: "night", context: operator)["authorizes"]).to be(false)
    history = run.history(id: "night", context: operator)
    expect(history.size).to eq(3)
    expect(history[1]["worker_claim"]).to include("untrusted")
    expect(history.last["results"].first["commit_sha"]).to eq(Digest::SHA1.hexdigest("work-1"))
    expect(outbox.list(context: operator)).to be_empty
  end

  it "records no_work on an already-green baseline without pretending to fix anything" do
    expect(check("baseline", status: "passed").dig("state", "status")).to eq("no_work")
    expect(claim("worker", "unused")["lease"]).to be_nil
    expect(run.fetch(id: "night", context: operator)["attempts"]).to eq(0)
  end

  it "allows an explicitly configured green baseline when the task requires new work" do
    args = start_args.merge(id: "feature", baseline_green: "continue")
    run.start(**args)
    lease = run.claim(id: "feature", role: "verifier", request_id: "baseline", context: verifier)["lease"]
    result = gate.record(status: "passed", commit_sha: artifact["commit_sha"], source: "ci:baseline", configuration_digest: artifact["configuration_digest"], dependencies_digest: artifact["dependencies_digest"], checked_at: base)
    receipt = run.report_verification(id: "feature", token: lease["token"], artifact: artifact, results: [result], failures: [], progress_digest: "sha256:#{'f' * 64}", usage: usage, context: verifier)
    expect(receipt.dig("state", "status")).to eq("ready")
  end

  it "persists reservations and deadlines across instances and refuses identity reuse" do
    check("baseline")
    first = claim("worker", "job-1")
    reloaded = described_class.new(**options)
    expect(reloaded.claim(id: "night", role: "worker", request_id: "job-1", context: worker)).to eq(first)
    expect(first["charged_cost_microusd"]).to eq(110)
    expect(first["attempts"]).to eq(1)
    expect(reloaded.contract(id: "night", context: operator)["goal_digest"]).to eq(goal.digest)
    clock[:now] = base + 5
    expect(run.start(**start_args)["deadline_at"]).to eq((base + 600).iso8601(6))
    expect { run.start(**start_args.merge(executor_version: "changed")) }.to raise_error(k::IntegrityError)
    expect { run.claim(id: "night", role: "verifier", request_id: "job-1", context: verifier) }.to raise_error(k::IntegrityError)
  end

  it "blocks a worker from self-verifying even with an overly permissive role callback" do
    check("baseline")
    work("work-1")
    permissive = described_class.new(**options.merge(authorize: ->(*) { true }))
    expect { permissive.claim(id: "night", role: "verifier", request_id: "cheat", context: worker) }.to raise_error(k::AccessDenied)
  end

  it "keeps exact numeric diagnostics and requires no observed progress before stalling" do
    check("baseline")
    work("work-1")
    expect(check("verify-1").dig("state", "status")).to eq("ready")
    work("work-2")
    expect(check("verify-2").dig("state", "status")).to eq("stalled")
    expect(outbox.fetch(id: "unattended:night", context: operator)["status"]).to eq("open")
    expect(run.history(id: "night", context: operator).last["failures"].first["expected"]).to eq("90")
  end

  it "does not call a changed measurable outcome stalled merely because a failure name repeats" do
    check("baseline")
    work("work-1")
    check("verify-1")
    work("work-2")
    expect(check("verify-2", progress: "sha256:#{'1' * 64}").dig("state", "status")).to eq("ready")
  end

  it "stops admission at the durable total budget including verification calls" do
    args = start_args.merge(id: "small", limits: limits.merge(max_cost_microusd: 100))
    run.start(**args)
    lease = run.claim(id: "small", role: "verifier", request_id: "baseline", context: verifier)["lease"]
    result = gate.record(status: "failed", commit_sha: artifact["commit_sha"], source: "ci", configuration_digest: artifact["configuration_digest"], dependencies_digest: artifact["dependencies_digest"], checked_at: base)
    run.report_verification(id: "small", token: lease["token"], artifact: artifact, results: [result], failures: failures, progress_digest: "sha256:#{'f' * 64}", usage: usage, context: verifier)
    expect(run.claim(id: "small", role: "worker", request_id: "job", context: worker)["status"]).to eq("budget_exhausted")
  end

  it "never treats missing cost as zero or silently retries an unknown execution" do
    check("baseline")
    result = work("work-1", measured: nil)
    expect(result.dig("state", "status")).to eq("needs_approval")
    expect(result.dig("state", "usage_complete")).to be(false)
    expect(result.dig("state", "charged_cost_microusd")).to eq(110)
    expect(claim("worker", "retry")["lease"]).to be_nil
  end

  it "reports actual overspend rather than capping measured cost to its reservation" do
    check("baseline")
    result = work("work-1", measured: { cost_microusd: 150, tokens: 100 })
    expect(result.dig("state", "status")).to eq("budget_exhausted")
    expect(result.dig("state", "charged_cost_microusd")).to eq(160)
  end

  it "fences expired leases and records late results without allowing success" do
    check("baseline")
    lease = claim("worker", "job")["lease"]
    clock[:now] = base + 61
    expect(run.expire(id: "night", context: operator)["status"]).to eq("needs_approval")
    result = run.report_work(id: "night", token: lease["token"], artifact: artifact, worker_claim: "done", usage: usage, context: worker)
    expect(result["late"]).to be(true)
    expect(result.dig("state", "usage_complete")).to be(false)
    expect(claim("worker", "replacement")["lease"]).to be_nil
  end

  it "never resets an absolute run deadline on resume" do
    check("baseline")
    clock[:now] = base + 601
    restarted = described_class.new(**options)
    expect(restarted.expire(id: "night", context: operator).values_at("status", "reason")).to eq(%w[budget_exhausted absolute_deadline])
  end

  it "lists expired work for an authorized scoped watchdog without exposing lease tokens" do
    check("baseline")
    lease = claim("worker", "job")["lease"]
    expect(run.due(context: operator)).to be_empty
    clock[:now] = base + 61
    expect(run.due(context: operator).map { |r| r["id"] }).to eq(["night"])
    expect(run.due(context: operator).to_s).not_to include(lease["token"])
    other = Agentkit::Context.new(account: Account.create!(name: "Other"), principal: "operator")
    expect(run.due(context: other)).to be_empty
    run.expire(id: "night", context: operator)
    expect(run.due(context: operator)).to be_empty
  end

  it "rejects protected changes and independently observed artifact mismatches" do
    check("baseline")
    work("work-1")
    actual = run.fetch(id: "night", context: operator)["artifact"].merge("protected_digest" => "sha256:#{'0' * 64}")
    expect(check("verify-1", status: "passed", observed: actual).dig("state", "status")).to eq("policy_violation")
  end

  it "cannot accept missing gate evidence as passed" do
    expect(check("baseline", status: "passed", results: []).dig("state", "status")).to eq("verification_unavailable")
  end

  it "cannot accept passed gates from an old commit" do
    result = gate.record(status: "passed", commit_sha: "9" * 40, source: "old-ci", configuration_digest: artifact["configuration_digest"], dependencies_digest: artifact["dependencies_digest"], checked_at: base)
    expect(check("baseline", status: "passed", results: [result]).dig("state", "status")).to eq("verification_unavailable")
  end

  it "requires checks recorded during the current verification lease" do
    result = gate.record(status: "passed", commit_sha: artifact["commit_sha"], source: "old-ci", configuration_digest: artifact["configuration_digest"], dependencies_digest: artifact["dependencies_digest"], checked_at: base - 1)
    expect(check("baseline", status: "passed", results: [result]).dig("state", "status")).to eq("verification_unavailable")
  end

  it "keeps pending verification distinct from failure or success" do
    expect(check("baseline", status: "pending").dig("state", "status")).to eq("verification_unavailable")
  end

  it "limits attempts even when successive failures look different" do
    check("baseline")
    3.times do |i|
      work("work-#{i}")
      check("check-#{i}", progress: Agentkit::Harness.digest(i))
    end
    expect(claim("worker", "work-4")["status"]).to eq("budget_exhausted")
  end

  it "does not erase meaningful numbers when fingerprinting errors" do
    check("baseline")
    work("work-1")
    check("verify-1")
    work("work-2")
    changed = failures.map { |f| f.merge(actual: "81") }
    expect(check("verify-2", diagnostics: changed).dig("state", "status")).to eq("ready")
  end

  it "does not accept a different principal reporting work with a worker token" do
    check("baseline")
    lease = claim("worker", "job")["lease"]
    permissive = described_class.new(**options.merge(authorize: ->(*) { true }))
    expect { permissive.report_work(id: "night", token: lease["token"], artifact: artifact, worker_claim: "done", usage: usage, context: verifier) }.to raise_error(k::AccessDenied)
  end

  it "rejects relaxed goal protections and malformed resource budgets before creation" do
    expect { run.start(**start_args.merge(id: "bad", protected_resources: ["other/"])) }.to raise_error(k::InvalidContract)
    expect { run.start(**start_args.merge(id: "bad", limits: limits.merge(max_attempts: 4))) }.to raise_error(k::InvalidContract)
    expect { run.start(**start_args.merge(id: "bad", limits: limits.merge(call_seconds: 601))) }.to raise_error(k::InvalidContract)
    expect { run.start(**start_args.merge(id: "bad", allowed_resources: ["tests/"])) }.to raise_error(k::InvalidContract)
    different_gate = Agentkit::Harness::VerificationGate.new(id: "unrelated", description: "irrelevant check")
    expect { run.start(**start_args.merge(id: "bad", gates: [different_gate])) }.to raise_error(k::InvalidContract)
  end

  it "isolates runs and revokes worker access before work receipts are accepted" do
    other = Agentkit::Context.new(account: Account.create!(name: "Other"), principal: "operator")
    expect(run.fetch(id: "night", context: other)).to be_nil
    expect { run.history(id: "night", context: other) }.to raise_error(ActiveRecord::RecordNotFound)
    check("baseline")
    lease = claim("worker", "work")["lease"]
    expect(run.fetch(id: "night", context: operator).to_s).not_to include(lease["token"])
    policy[:worker] = false
    expect { run.report_work(id: "night", token: lease["token"], artifact: artifact, worker_claim: "done", usage: usage, context: worker) }.to raise_error(k::AccessDenied)
  end

  it "rolls back reservations if claim audit fails and terminal transitions if escalation fails" do
    check("baseline")
    policy[:rollback] = true
    expect { claim("worker", "work") }.to raise_error(k::IntegrityError)
    policy[:rollback] = false
    expect(run.fetch(id: "night", context: operator)["attempts"]).to eq(0)
    allow(outbox).to receive(:enqueue).and_raise("outbox down")
    expect { run.cancel(id: "night", reason: "stop", context: operator) }.to raise_error("outbox down")
    expect(run.fetch(id: "night", context: operator)["status"]).to eq("ready")
  end

  it "replays a completed receipt without charging twice and rejects altered retries" do
    check("baseline")
    lease = claim("worker", "job")["lease"]
    args = { id: "night", token: lease["token"], artifact: artifact, worker_claim: "attempted", usage: usage, context: worker }
    first = run.report_work(**args)
    expect(run.report_work(**args)).to eq(first)
    expect(run.fetch(id: "night", context: operator)["charged_cost_microusd"]).to eq(20)
    expect(claim("worker", "job")["lease"]).to be_nil
    expect { run.report_work(**args.merge(worker_claim: "changed")) }.to raise_error(k::IntegrityError)
  end

  it "admits only one of two concurrent workers", :real_concurrency do
    check("baseline")
    worker
    start = Queue.new
    threads = %w[job-a job-b].map do |id|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          start.pop
          claim("worker", id)
        end
      end
    end
    2.times { start << true }
    results = threads.map(&:value)
    expect(results.count { |r| r["lease"] }).to eq(1)
    expect(run.fetch(id: "night", context: operator)["attempts"]).to eq(1)
  end

  it "does not grant a lease from an uncommitted caller-owned transaction" do
    ActiveRecord::Base.transaction do
      expect { claim("verifier", "job") }.to raise_error(k::InvalidContract, /outside a caller transaction/)
    end
    expect(run.fetch(id: "night", context: operator)["charged_cost_microusd"]).to eq(0)
  end
end
