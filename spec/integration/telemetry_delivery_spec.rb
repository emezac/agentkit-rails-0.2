# frozen_string_literal: true

require "rails_helper"
require "rake"
require "stringio"

RSpec.describe "Telemetry delivery and diagnosis", :integration do
  it "deduplicates retries after PostgreSQL committed but acknowledgement failed", :real_concurrency do
    backend = Agentkit::Telemetry::Backends::ActiveRecordBackend.new
    Agentkit::Telemetry.backends = [backend]
    original = backend.method(:write)
    calls = 0
    allow(backend).to receive(:write) do |batch|
      original.call(batch)
      calls += 1
      raise IOError if calls == 1
    end
    event = Agentkit::Telemetry.emit("delivery.test")
    2.times { Agentkit::Telemetry.flush! }
    expect(Agentkit::EventRecord.where(event_id: event.event_id).count).to eq(1)
    expect(backend.events(name: "delivery.test").first.event_id).to eq(event.event_id)
    expect(Agentkit::Telemetry.delivery_health[:pending_deliveries]).to eq(0)
  end

  it "diagnoses only the selected tenant and account rather than other activity" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("agentkit:doctor")
    task = Rake::Task["agentkit:doctor"]
    previous_env = ENV.to_h.slice("TENANT", "ACCOUNT_ID")
    previous_stdout = $stdout
    Agentkit.config.multi_tenant = true
    ENV["TENANT"], ENV["ACCOUNT_ID"] = "tenant-a", "42"
    Agentkit::Telemetry.emit("other.tenant", dims: { tenant: "tenant-b", account_id: 42 })
    Agentkit::Telemetry.emit("other.account", dims: { tenant: "tenant-a", account_id: 43 })
    output = StringIO.new
    $stdout = output
    task.reenable
    task.invoke
    expect(output.string).to include("No telemetry in the last 7 days")
    Agentkit::Telemetry.emit("matching", dims: { tenant: "tenant-a", account_id: 42 })
    output.truncate(0)
    output.rewind
    task.reenable
    task.invoke
    expect(output.string).to include("Telemetry active (1 events / 7d)")
  ensure
    $stdout = previous_stdout
    %w[TENANT ACCOUNT_ID].each { |key| ENV[key] = previous_env[key] }
    Agentkit.config.multi_tenant = false
    task&.reenable
  end
end
