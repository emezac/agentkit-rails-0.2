# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentkit::Telemetry do
  let(:memory) { Agentkit::Telemetry::Backends::MemoryBackend.new }

  before do
    Agentkit.config.telemetry.enabled = true
    Agentkit.config.telemetry.flush_size = 200
    described_class.backends = [memory]
  end

  it "does not replay an acknowledged sink when another sink fails" do
    failing = double("idempotent sink", idempotent?: true)
    allow(failing).to receive(:write).and_raise(IOError)
    described_class.backends = [memory, failing]
    event = described_class.emit("test")
    described_class.flush!
    expect(described_class.delivery_health).to include(pending_deliveries: 1, failed_writes: 1)
    expect(memory).not_to receive(:write)
    expect(failing).to receive(:write).with([event]).and_return(true)
    described_class.flush!
    expect(described_class.delivery_health).to include(pending_deliveries: 0, dropped_deliveries: 0)
    expect(memory.events.size).to eq(1)
  end

  it "deduplicates an ambiguous acknowledgement at an idempotent sink" do
    original = memory.method(:write)
    calls = 0
    allow(memory).to receive(:write) do |batch|
      original.call(batch)
      calls += 1
      raise IOError if calls == 1
    end
    described_class.emit("test")
    2.times { described_class.flush! }
    expect(memory.events.size).to eq(1)
    expect(described_class.delivery_health[:pending_deliveries]).to eq(0)
  end

  it "reports ambiguous loss instead of retrying a non-idempotent sink" do
    sink = double("external sink")
    expect(sink).to receive(:write).once.and_raise(IOError)
    described_class.backends = [sink]
    described_class.emit("test")
    2.times { described_class.flush! }
    expect(described_class.delivery_health).to include(dropped_deliveries: 1, complete: false)
  end

  it "accepts new events during a slow flush and serializes concurrent flushes" do
    entered, release = Queue.new, Queue.new
    original = memory.method(:write)
    allow(memory).to receive(:write) do |batch|
      entered << true
      release.pop
      original.call(batch)
    end
    first = described_class.emit("first")
    worker = Thread.new { described_class.flush! }
    entered.pop
    second = described_class.emit("second")
    expect(described_class.flush!).to eq([])
    expect(described_class.delivery_health[:complete]).to eq(false)
    release << true
    worker.value
    allow(memory).to receive(:write) { |batch| original.call(batch) }
    described_class.flush!
    expect(memory.events.map(&:event_id)).to contain_exactly(first.event_id, second.event_id)
  ensure
    release << true if release
    worker&.join
  end

  it "handles a sink that emits telemetry recursively without a deadlock" do
    Agentkit.config.telemetry.flush_size = 1
    original = memory.method(:write)
    allow(memory).to receive(:write) do |batch|
      described_class.emit("nested") if batch.any? { |event| event.name == "outer" }
      original.call(batch)
    end
    described_class.emit("outer")
    described_class.flush!
    expect(memory.events.map(&:name)).to contain_exactly("outer", "nested")
  end

  it "bounds failed deliveries and exposes overflow without disrupting emit" do
    stub_const("Agentkit::Telemetry::Delivery::LIMIT", 2)
    allow(memory).to receive(:write).and_raise(IOError)
    3.times { described_class.emit("test"); described_class.flush! }
    expect(described_class.delivery_health).to include(pending_deliveries: 2, dropped_deliveries: 1)
  end

  it "does not expose the mutable internal buffer" do
    described_class.emit("test")
    described_class.buffer.clear
    described_class.flush!
    expect(memory.events.size).to eq(1)
  end
end
