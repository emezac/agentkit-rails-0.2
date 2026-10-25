# frozen_string_literal: true

require "rails_helper"
require_relative "../../examples/rails_evidence"

RSpec.describe "Controlled Business Experiments", :integration do
  let(:k) { Agentkit::Knowledge }
  let(:account) { Account.create!(name: "Experiment", plan: "pro") }
  let(:context) { Agentkit::Context.new(account: account, principal: "author") }
  let(:reviewer) { Agentkit::Context.new(account: account, principal: "human-reviewer") }
  let(:base) { Time.now.utc }
  let(:clock) { { now: base } }
  let(:gate) do
    RailsEvidenceExample.build(model: Widget, authorize_record: ->(*) { true }, authorize_decision: ->(*) { true },
      authorize_journal: ->(*) { true }, execution_context: ->(*) { context },
      approved_by: "human-reviewer", approved_at: "2020-01-01T00:00:00Z")
  end
  let(:options) do
    { name: "checkout", version: "1", hypothesis: "simplified flow improves conversion", unit: "customer",
      metrics: { conversion: { min: 0, max: 1, direction: "maximize" } }, primary_metric: "conversion",
      starts_at: (base + 60).iso8601(6), enrollment_ends_at: (base + 3600).iso8601(6),
      analysis_at: (base + 7200).iso8601(6), window_seconds: 60, max_units: 500, min_per_arm: 20,
      gates: { control: gate.digest, treatment: gate.digest }, evidence_versions: { cohort: "1", measurement: "1" },
      variants: { control: { flow: "original" }, treatment: { flow: "simplified" } },
      journal: gate.journal, authorize: ->(*) { true }, eligible: ->(*) { true },
      bind_unit: ->(id, args, _ctx) { id == "widget:#{args.fetch('id')}" }, clock: -> { clock[:now] } }
  end
  subject(:experiment) { k::BusinessExperiment.new(**options) }

  def launch
    experiment.register(context: context)
    experiment.approve(reason: "bounded pilot", context: reviewer)
    clock[:now] = base + 120
  end

  def finish(unit_id, value: 1)
    experiment.outcome(unit_id: unit_id, values: { conversion: value }, source: "ledger/#{unit_id}",
      source_version: "1", observed_at: clock[:now].iso8601(6), context: context)
  end

  it "freezes a protocol and requires independent approval before enrollment" do
    experiment.register(context: context)
    expect { experiment.approve(reason: "self", context: context) }.to raise_error(k::AccessDenied)
    expect { experiment.assign(unit_id: "a", context: context) }.to raise_error(k::DecisionDenied)
    changed = k::BusinessExperiment.new(**options.merge(hypothesis: "different"))
    expect { changed.register(context: context) }.to raise_error(k::IntegrityError)
    expect(experiment.fetch(type: "registration", context: context)).not_to have_key("seed")
    clock[:now] = base + 120
    expect { experiment.approve(reason: "late", context: reviewer) }.to raise_error(k::InvalidContract)
  end

  it "keeps deterministic assignments across instances and rejects ineligible units" do
    launch
    first = experiment.assign(unit_id: "stable", context: context)
    reloaded = k::BusinessExperiment.new(**options)
    expect(reloaded.assign(unit_id: "stable", context: context)).to eq(first)
    expect(Agentkit::BusinessExperimentRecord.first.runtime.fetch("units").size).to eq(1)
    denied = k::BusinessExperiment.new(**options.merge(eligible: ->(*) { false }))
    expect { denied.assign(unit_id: "other", context: context) }.to raise_error(k::AccessDenied)
  end

  it "enforces a global quota and enrollment horizon" do
    small = k::BusinessExperiment.new(**options.merge(max_units: 40))
    small.register(context: context)
    small.approve(reason: "pilot", context: reviewer)
    clock[:now] = base + 120
    40.times { |i| small.assign(unit_id: "u#{i}", context: context) }
    expect { small.assign(unit_id: "overflow", context: context) }.to raise_error(k::DecisionDenied)
    clock[:now] = base + 3600
    expect(small.assign(unit_id: "u0", context: context)["unit_key"]).not_to be_empty
    expect { small.assign(unit_id: "late", context: context) }.to raise_error(k::DecisionDenied)
  end

  it "executes once through the approved gate and persists exposure with the same transaction" do
    launch
    widget = account.widgets.create!(name: "Original", status: "ready")
    unit = "widget:#{widget.id}"
    assignment = experiment.assign(unit_id: unit, context: context)
    args = { unit_id: unit, gate: gate, arguments: { id: widget.id }, context: context }
    result = experiment.execute(**args) { |arm| widget.update!(name: arm); { applied: arm } }
    expect(result["arm"]).to eq(assignment["arm"])
    expect(experiment.execute(**args) { raise "duplicate" }).to eq(result)
    expect(experiment.fetch(type: "exposure", unit_id: unit, context: context)["execution_key"]).to eq(result["execution_key"])
    experiment.stop(reason: "safety", context: reviewer)
    expect { experiment.execute(**args) { raise "unsafe" } }.to raise_error(k::DecisionDenied)
  end

  it "rolls back business effects when exposure persistence fails" do
    launch
    widget = account.widgets.create!(name: "Original", status: "ready")
    unit = "widget:#{widget.id}"
    experiment.assign(unit_id: unit, context: context)
    allow(experiment).to receive(:write).and_wrap_original do |method, key, *rest|
      raise "storage failure" if key.start_with?("exposure:")
      method.call(key, *rest)
    end
    expect { experiment.execute(unit_id: unit, gate: gate, arguments: { id: widget.id }, context: context) { widget.update!(name: "Changed"); {} } }.to raise_error("storage failure")
    expect(widget.reload.name).to eq("Original")
    expect(Agentkit::KnowledgeEntryRecord.where(kind: "execution").count).to eq(0)
  end

  it "rejects cross-unit execution and protocol gate drift" do
    launch
    widget = account.widgets.create!(name: "Original", status: "ready")
    experiment.assign(unit_id: "another-unit", context: context)
    expect { experiment.execute(unit_id: "another-unit", gate: gate, arguments: { id: widget.id }, context: context) {} }.to raise_error(k::AccessDenied)
    unit = "widget:#{widget.id}"
    experiment.assign(unit_id: unit, context: context)
    expect { experiment.execute(unit_id: unit, gate: Object.new, arguments: { id: widget.id }, context: context) {} }.to raise_error(k::InvalidContract)
  end

  it "requires mature bounded outcomes and rejects corrections under the same identity" do
    launch
    experiment.assign(unit_id: "a", context: context)
    expect { finish("a") }.to raise_error(k::InvalidContract)
    clock[:now] = base + 240
    expect { finish("a", value: 2) }.to raise_error(k::InvalidContract)
    first = finish("a")
    clock[:now] = base + 300
    expect(experiment.outcome(unit_id: "a", values: { conversion: 1 }, source: "ledger/a", source_version: "1",
      observed_at: first["observed_at"], context: context)).to eq(first)
    expect { finish("a", value: 0) }.to raise_error(k::IntegrityError)
  end

  it "includes missing and unexposed assigned units and refuses early analysis" do
    launch
    experiment.assign(unit_id: "a", context: context)
    expect { experiment.analyze(context: context) }.to raise_error(k::InvalidContract)
    clock[:now] = base + 7300
    # Late receipt with backdated observation must remain unavailable at cutoff.
    experiment.outcome(unit_id: "a", values: { conversion: 1 }, source: "ledger", source_version: "1",
      observed_at: (base + 300).iso8601(6), context: context)
    report = experiment.analyze(context: context)
    expect(report["reasons"]).to include("missing_outcomes", "insufficient_sample")
    expect(report["counts"].values.sum { |v| v["assigned"] }).to eq(1)
    expect(report["counts"].values.sum { |v| v["exposed"] }).to eq(0)
    expect(report["estimates"]).to be_empty
    expect(experiment.analyze(context: context)).to eq(report)
    expect { finish("a") }.to raise_error(k::InvalidContract)
  end

  it "computes a conservative intention-to-treat report without automatic promotion" do
    allow(SecureRandom).to receive(:hex).and_call_original
    allow(SecureRandom).to receive(:hex).with(32).and_return("test-seed")
    launch
    # Fixed seed is test-only; production registration always uses SecureRandom.
    assignments = 160.times.map { |i| ["u#{i}", experiment.assign(unit_id: "u#{i}", context: context)] }
    clock[:now] = base + 240
    assignments.each { |unit, assignment| finish(unit, value: assignment["arm"] == "treatment" ? 1 : 0) }
    clock[:now] = base + 7200
    report = experiment.analyze(context: context)
    expect(report["status"]).to eq("eligible_for_human_review")
    expect(report["estimates"]["conversion"]["treatment_minus_control"]).to eq("1")
    expect(report["estimates"]["conversion"]["benefit_lower"].to_f).to be > 0
    expect(report["causal_proof"]).to eq(false)
    expect(report["auto_promoted"]).to eq(false)
    expect(report["rows"].size).to eq(160)
    expect { experiment.review_result(approve: true, reason: "self", context: context) }.to raise_error(k::AccessDenied)
    review = experiment.review_result(approve: true, reason: "reviewed assumptions", context: reviewer)
    expect(review["report_digest"]).to eq(k.digest(report))
    experiment.revoke_result(reason: "measurement defect", context: reviewer)
    expect { experiment.review_result(approve: true, reason: "retry", context: reviewer) }.to raise_error(k::DecisionDenied)
  end

  it "stops enrollment permanently while preserving outcomes for audit" do
    launch
    experiment.assign(unit_id: "a", context: context)
    experiment.stop(reason: "adverse event", context: reviewer)
    expect { experiment.assign(unit_id: "b", context: context) }.to raise_error(k::DecisionDenied)
    clock[:now] = base + 240
    finish("a")
    clock[:now] = base + 7200
    expect(experiment.analyze(context: context)["reasons"]).to include("stopped")
  end

  it "isolates tenants and enforces authorization on reads and writes" do
    experiment.register(context: context)
    denied = k::BusinessExperiment.new(**options.merge(authorize: ->(*) { false }))
    expect { denied.fetch(type: "registration", context: context) }.to raise_error(k::AccessDenied)
    other = Agentkit::Context.new(account: Account.create!(name: "Other"), principal: "reader")
    expect { experiment.fetch(type: "registration", context: other) }.to raise_error(ActiveRecord::RecordNotFound)
    expect(experiment.register(context: other)["registered_by"]).to eq("reader")
  end

  it "serializes duplicate enrollment across workers", :real_concurrency do
    launch
    ctx, instance = context, experiment
    results = 4.times.map do
      Thread.new { ActiveRecord::Base.connection_pool.with_connection { instance.assign(unit_id: "same", context: ctx) } }
    end.map(&:value)
    expect(results.uniq.size).to eq(1)
    expect(Agentkit::BusinessExperimentRecord.first.runtime.fetch("units").size).to eq(1)
  end

  it "detects seed corruption and refuses to approve an inconclusive report" do
    launch
    clock[:now] = base + 7200
    experiment.analyze(context: context)
    expect { experiment.review_result(approve: true, reason: "override", context: reviewer) }.to raise_error(k::DecisionDenied)
    row = Agentkit::BusinessExperimentRecord.first
    row.update!(runtime: row.runtime.merge("seed" => "tampered"))
    expect { experiment.fetch(type: "analysis", context: context) }.to raise_error(k::IntegrityError)
  end

  it "does not oversubscribe the final quota slot across workers", :real_concurrency do
    instance = k::BusinessExperiment.new(**options.merge(max_units: 40))
    instance.register(context: context)
    instance.approve(reason: "pilot", context: reviewer)
    clock[:now] = base + 120
    39.times { |i| instance.assign(unit_id: "u#{i}", context: context) }
    ctx = context
    results = 2.times.map do |i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          instance.assign(unit_id: "final#{i}", context: ctx)
          :assigned
        rescue Agentkit::Knowledge::DecisionDenied
          :quota
        end
      end
    end.map(&:value)
    expect(results.sort).to eq(%i[assigned quota])
    expect(Agentkit::BusinessExperimentRecord.first.runtime.fetch("units").size).to eq(40)
  end
end
