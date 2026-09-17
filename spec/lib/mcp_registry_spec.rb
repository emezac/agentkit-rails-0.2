# frozen_string_literal: true

require "spec_helper"
require "agentkit/mcp"

RSpec.describe Agentkit::MCP::Registry do
  it "lists and invokes only explicitly exposed capabilities" do
    exposed = Agentkit::Capability.register :read_account do |cap|
      cap.input_schema type: "object", properties: {}, additionalProperties: false
      cap.effect :read_only
      cap.risk :read
      cap.executor { { id: 1 } }
      cap.expose :mcp
    end
    Agentkit::Capability.register(:hidden) { |cap| cap.executor { {} } }
    registry = described_class.new
    registry.expose(exposed)

    expect(registry.list.map { |tool| tool[:name] }).to eq(["agentkit.read_account"])
    principal = Agentkit::Principal.new(id: "mcp:user")
    expect(registry.call("agentkit.read_account", arguments: {}, principal: principal)[:result])
      .to eq(id: 1)
    expect { registry.expose(:hidden) }.to raise_error(Agentkit::ConfigurationError, /not explicitly exposed/)
  end

  it "never exposes irreversible execution" do
    cap = Agentkit::Capability.register :delete_account do |value|
      value.risk :irreversible
      value.executor { {} }
      value.expose :mcp, mode: :execute
    end
    expect { described_class.new.expose(cap) }
      .to raise_error(Agentkit::ConfigurationError, /may only be proposed/)
  end

  it "conforms to the official SDK tools/list and tools/call boundary" do
    cap = Agentkit::Capability.register :official_echo do |value|
      value.input_schema type: "object", properties: { message: { type: "string" } },
                         required: ["message"], additionalProperties: false
      value.effect :read_only
      value.risk :read
      value.executor { |arguments| { echo: arguments[:message] } }
      value.expose :mcp
    end
    registry = described_class.new
    registry.expose(cap)
    principal = Agentkit::Principal.new(id: "mcp:conformance")
    server = Agentkit::MCP::Server.new(registry: registry).sdk_server(principal: principal)

    listed = server.handle({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} })
    called = server.handle({ jsonrpc: "2.0", id: 2, method: "tools/call",
                             params: { name: "agentkit.official_echo",
                                       arguments: { message: "hello" } } })

    expect(listed.dig(:result, :tools).map { |tool| tool[:name] })
      .to eq(["agentkit.official_echo"])
    expect(called.dig(:result, :content, 0, :text)).to include('"echo":"hello"')
    expect(listed.dig(:result, :tools).map { |tool| tool[:name] }.grep(/approve/i)).to be_empty
  end

  it "authenticates before delegating protocol body parsing" do
    delegated = false
    app = ->(_env) { delegated = true; [200, {}, []] }
    boundary = Agentkit::MCP::RackApp.new(app, authenticator: ->(_env) { nil })
    status, = boundary.call("rack.input" => Object.new)

    expect(status).to eq(401)
    expect(delegated).to be(false)
  end
end
