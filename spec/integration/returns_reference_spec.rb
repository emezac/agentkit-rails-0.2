# frozen_string_literal: true
require "rails_helper"
require "open3"
require "uri"
require_relative "../../examples/returns_app/lib/returns_reference"
require_relative "../../examples/returns_app/lib/refund_delivery_job"
require_relative "../../examples/returns_app/db/migrate/20261126000000_create_reference_returns"

ActiveRecord::Migration.suppress_messages do
  CreateReferenceReturns.new.migrate(:up) unless ActiveRecord::Base.connection.table_exists?(:reference_returns)
end

RSpec.describe "Rails returns reference application", :integration, :real_concurrency do
  it "boots without a database only for explicit provisioning tasks" do
    url = URI.parse(ENV.fetch("DATABASE_URL", "postgresql://localhost/agentkit_dummy_test"))
    url.path = "/reference_absent_#{SecureRandom.hex(8)}"
    environment = File.expand_path("../../examples/returns_app/config/environment", __dir__)
    [true, false].each do |provisioning|
      script = <<~RUBY
        require "rake"
        Rake.application.top_level_tasks << "db:create" if #{provisioning}
        require #{environment.inspect}
        ActiveRecord::Base
        puts "booted"
      RUBY
      output, error, status = Open3.capture3(
        { "RETURNS_DATABASE_URL" => url.to_s }, RbConfig.ruby, "-e", script)
      if provisioning
        expect(status.success?).to eq(true), error
        expect(output).to include("booted")
      else
        expect(status.success?).to eq(false)
        expect(error).to include("NoDatabaseError")
      end
    end
  end

  let(:k) { Agentkit::Knowledge }
  let(:account) { Account.create!(name: "Shop", plan: "pro") }
  let(:requester) { Agentkit::Context.new(account: account, principal: "customer") }
  let(:reviewer) { Agentkit::Context.new(account: account, principal: "reviewer") }
  let(:worker) { Agentkit::Context.new(account: account, principal: "worker") }
  let(:time) { { now: Time.now.utc } }
  let(:provider) { ReturnsReference::SimulatedProvider.new }
  let(:policy) do
    ->(action, ctx) {
      { "request" => %w[customer], "approve" => %w[reviewer customer],
        "enqueue" => %w[worker], "deliver" => %w[worker], "reconcile" => %w[worker],
        "learning" => %w[worker], "experiment" => %w[worker reviewer],
        "journal" => %w[worker reviewer] }.fetch(action, []).include?(ctx.principal)
    }
  end
  let(:workflow) { ReturnsReference::Workflow.new(authorize: policy, provider: provider, clock: -> { time[:now] }) }

  def approved
    row = workflow.request(amount_cents: 500, context: requester)
    workflow.approve(id: row.id, context: reviewer)
    row
  end

  def queued
    workflow.enqueue(id: approved.id, context: worker).fetch("intent_id")
  end

  it "revalidates approval and queues once before independently confirming the refund" do
    row = approved
    first = workflow.enqueue(id: row.id, context: worker)
    expect(workflow.enqueue(id: row.id, context: worker)).to eq(first)
    expect(ReturnsReference::ProviderRefund.count).to eq(0)
    workflow.deliver(id: first.fetch("intent_id"), context: worker)
    workflow.deliver(id: first.fetch("intent_id"), context: worker)
    expect(ReturnsReference::ProviderRefund.count).to eq(1)
    expect(row.reload.status).to eq("refunded")
    time[:now] += 120
    result = workflow.record_outcome(id: first.fetch("intent_id"), context: worker)
    expect(result.fetch("values")).to eq("refunded_cents" => 500)
    time[:now] += 60
    expect(workflow.record_outcome(id: first.fetch("intent_id"), context: worker)).to eq(result)
  end

  it "denies self-approval, changed amounts, and foreign-tenant work" do
    row = workflow.request(amount_cents: 500, context: requester)
    expect { workflow.approve(id: row.id, context: requester) }.to raise_error(k::AccessDenied)
    workflow.approve(id: row.id, context: reviewer)
    row.update!(amount_cents: 600)
    expect { workflow.enqueue(id: row.id, context: worker) }.to raise_error(k::DecisionDenied)
    foreign = Agentkit::Context.new(tenant_key: "foreign", account: account, principal: "worker")
    expect { workflow.enqueue(id: row.id, context: foreign) }.to raise_error(ActiveRecord::RecordNotFound)
    expect(ReturnsReference::Intent.count).to eq(0)
  end

  it "rolls the intent and receipt back together and refuses provider calls in caller transactions" do
    row = approved
    ReturnsReference::Intent.transaction do
      workflow.enqueue(id: row.id, context: worker)
      raise ActiveRecord::Rollback
    end
    expect(ReturnsReference::Intent.count).to eq(0)
    id = workflow.enqueue(id: row.id, context: worker).fetch("intent_id")
    ReturnsReference::Intent.transaction do
      expect { workflow.deliver(id: id, context: worker) }.to raise_error(k::InvalidContract)
    end
    expect(ReturnsReference::ProviderRefund.count).to eq(0)
  end

  it "reconciles a provider success followed by a lost response without refunding twice" do
    id = queued
    original = provider.method(:refund)
    allow(provider).to receive(:refund) do |**args|
      original.call(**args)
      raise IOError, "lost response"
    end
    expect { workflow.deliver(id: id, context: worker) }.to raise_error(IOError)
    expect(ReturnsReference::Intent.find(id).status).to eq("unknown")
    recovered = ReturnsReference::Workflow.new(authorize: policy, clock: -> { time[:now] })
    expect(recovered.deliver(id: id, context: worker)).to be_nil
    recovered.reconcile(id: id, context: worker)
    expect(ReturnsReference::Intent.find(id).status).to eq("confirmed")
    expect(ReturnsReference::ProviderRefund.count).to eq(1)
  end

  it "requires reconciliation after a lease expires before the provider was called" do
    id = queued
    workflow.claim(id: id, context: worker)
    time[:now] += 61
    expect(workflow.deliver(id: id, context: worker)).to be_nil
    expect { workflow.record_outcome(id: id, context: worker) }.to raise_error(k::InvalidContract)
    workflow.reconcile(id: id, context: worker)
    workflow.deliver(id: id, context: worker)
    expect(ReturnsReference::ProviderRefund.count).to eq(1)
  end

  it "keeps uncertainty when lookup fails and rejects a mismatched confirmation" do
    id = queued
    allow(provider).to receive(:refund).and_return({ "key" => "wrong" })
    expect { workflow.deliver(id: id, context: worker) }.to raise_error(k::IntegrityError)
    allow(provider).to receive(:lookup).and_raise(IOError)
    expect { workflow.reconcile(id: id, context: worker) }.to raise_error(IOError)
    expect(ReturnsReference::Intent.find(id).status).to eq("unknown")
  end

  it "admits only one concurrent delivery and requires trusted worker scope" do
    id = queued
    context = worker
    service = workflow
    leases = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { service.claim(id: id, context: context) }
      end
    end.map(&:value).compact
    expect(leases.size).to eq(1)
    job = ReturnsReference::RefundDeliveryJob
    job.workflow_factory = -> { service }
    job.context_resolver = ->(*) { context }
    expect { job.new.perform(id, "foreign", account.id) }.to raise_error(k::AccessDenied)
  ensure
    ReturnsReference::RefundDeliveryJob.workflow_factory = nil
    ReturnsReference::RefundDeliveryJob.context_resolver = nil
  end

  it "does not accept a late provider result until it is independently reconciled" do
    id = queued
    original = provider.method(:refund)
    allow(provider).to receive(:refund) do |**args|
      result = original.call(**args)
      time[:now] += 61
      result
    end
    expect { workflow.deliver(id: id, context: worker) }.to raise_error(k::IntegrityError)
    expect(ReturnsReference::Intent.find(id).status).to eq("unknown")
    workflow.reconcile(id: id, context: worker)
    expect(ReturnsReference::Intent.find(id).status).to eq("confirmed")
    expect(ReturnsReference::ProviderRefund.count).to eq(1)
  end

  it "binds controlled pilot exposure to the approved gate and selected delivery queue" do
    base = time[:now]
    pilot = workflow.pilot(starts_at: base + 60, enrollment_ends_at: base + 3600, analysis_at: base + 7200)
    pilot.register(context: worker)
    pilot.approve(reason: "bounded routing pilot", context: reviewer)
    row = approved
    time[:now] += 120
    assignment = pilot.assign(unit_id: row.id.to_s, context: worker)
    result = workflow.enqueue_pilot(id: row.id, pilot: pilot, context: worker)
    intent = ReturnsReference::Intent.find(result.fetch("output").fetch("intent_id"))
    expect(intent.execution_key).to eq(result.fetch("execution_key"))
    expect(intent.delivery_queue).to eq(assignment.fetch("arm") == "control" ? "standard" : "specialist")
    workflow.deliver(id: intent.id, context: worker)
    time[:now] += 120
    pilot.outcome(unit_id: row.id.to_s, values: { handling_seconds: 30 }, source: "host-timer/#{row.id}",
      source_version: "1", observed_at: time[:now].iso8601(6), context: worker)
    pilot.stop(reason: "end demonstration", context: reviewer)
    time[:now] = base + 7201
    expect(pilot.analyze(context: worker).to_s).to include("insufficient")
  end
end
