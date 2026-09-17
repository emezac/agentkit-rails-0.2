# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Audit v2" do
  before do
    Agentkit.config.audit.store = :memory
    Agentkit.config.audit.signing_keys = { "spec" => "a-secret-signing-key" }
    Agentkit.config.audit.active_key_id = "spec"
  end

  it "builds and verifies independent tenant chains" do
    2.times do |index|
      Agentkit::Audit.record(event_type: "action.#{index}", payload: { index: index },
                             context: Agentkit::Context.new(tenant_key: "a", principal: "user:1"))
    end
    Agentkit::Audit.record(event_type: "action.0", payload: {},
                           context: Agentkit::Context.new(tenant_key: "b", principal: "user:2"))

    expect(Agentkit::Audit.verify!(tenant_key: "a")).to include(valid: true, entries: 2)
    expect(Agentkit::Audit.verify!(tenant_key: "b")).to include(valid: true, entries: 1)
  end

  it "detects payload tampering" do
    entry = Agentkit::Audit.record(event_type: "action", payload: { amount: 10 },
                                   context: Agentkit::Context.new(tenant_key: "a"))
    entry.payload["amount"] = 999

    expect { Agentkit::Audit.verify!(tenant_key: "a") }
      .to raise_error(Agentkit::AuditIntegrityError, /payload digest/)
  end
end
