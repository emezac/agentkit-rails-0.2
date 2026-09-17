# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Capability contract v2" do
  it "enforces closed input and output schemas" do
    capability = Agentkit::Capability.register :lookup do |cap|
      cap.input_schema type: "object", properties: { id: { type: "integer" } },
                       required: ["id"], additionalProperties: false
      cap.output_schema type: "object", properties: { name: { type: "string" } },
                        required: ["name"], additionalProperties: false
      cap.effect :read_only
      cap.risk :read
      cap.executor { |_arguments| { name: "Acme" } }
    end

    expect(capability.execute(id: 1)).to eq(name: "Acme")
    expect { capability.execute(id: 1, injected: true) }
      .to raise_error(Agentkit::SchemaValidationError, /input/)
  end

  it "rejects external contracts without required idempotency and reconciliation" do
    expect do
      Agentkit::Capability.register(:unsafe) do |cap|
        cap.effect :external
        cap.executor { {} }
      end
    end.to raise_error(Agentkit::ConfigurationError, /idempotency/)
  end

  it "requires explicit adapter exposure" do
    cap = Agentkit::Capability.register(:private_tool) { |value| value.executor { {} } }
    expect(cap.exposed?(:a2a)).to be(false)
    cap.expose :a2a, mode: :propose
    expect(cap.exposure_mode(:a2a)).to eq(:propose)
  end
end
