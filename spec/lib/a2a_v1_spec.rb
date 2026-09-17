# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentkit::A2A::V1 do
  let(:account) { AgentkitSpecHelpers::Account.new(42, "Proveedor Luna", "pro") }
  let(:context) { Agentkit::Context.new(account: account, tenant_key: "vendor-42") }

  before do
    Agentkit::A2A::V1.task_store = Agentkit::A2A::V1::TaskStore.new
    Agentkit.config.domain_name = "Eventos"
    Agentkit.config.a2a.enabled = true
    Agentkit.config.a2a.base_url = "https://agents.test"
    Agentkit.config.a2a.expose = [:quote_event]

    flow = Class.new(Agentkit::Flow) do
      def self.name = "QuoteEventFlow"
      step(:quote) { |ctx| { total: ctx.input[:budget].to_i, currency: "MXN" } }
    end
    Agentkit::Capability.register :quote_event do |cap|
      cap.title "Cotizar evento"
      cap.description "Genera una cotización"
      cap.flow flow
      cap.inputs budget: :integer
      cap.tags :events
      cap.risk :reversible
      cap.hitl :auto
      cap.expose :a2a
    end
  end

  describe ".card" do
    it "publishes an A2A 1.0, tenant-aware Agent Card" do
      card = described_class.card(context: context)

      expect(card[:name]).to eq("Proveedor Luna")
      expect(card[:supportedInterfaces]).to eq([
        { url: "https://agents.test/agentkit/a2a", protocolBinding: "HTTP+JSON",
          protocolVersion: "1.0", tenant: "vendor-42" }
      ])
      expect(card[:skills].map { |skill| skill[:id] }).to eq(["quote_event"])
      expect(card).to include(:securitySchemes, :securityRequirements)
    end

    it "allows a host to project domain fields without changing the kernel" do
      Agentkit.config.a2a.card_builder = lambda do |card, ctx|
        card.merge(iconUrl: "https://cdn.test/#{ctx.tenant_key}.png")
      end

      expect(described_class.card(context: context)[:iconUrl]).to end_with("vendor-42.png")
    end
  end

  describe "messages and tasks" do
    it "executes a standard message and returns a completed Task artifact" do
      task = described_class.send_message({
        message: { role: "ROLE_USER", messageId: "msg-1",
                   metadata: { skillId: "quote_event" }, parts: [{ data: { budget: 8_000 } }] }
      }, context: context)

      expect(task.dig(:status, :state)).to eq("TASK_STATE_COMPLETED")
      expect(task.dig(:artifacts, 0, :parts, 0, :data)).to eq(total: 8_000, currency: "MXN")
      expect(described_class.get_task(task[:id], context: context)[:id]).to eq(task[:id])
      expect(described_class.list_tasks(context: context).size).to eq(1)
    end

    it "requests missing structured input rather than failing the task" do
      task = described_class.send_message({
        message: { role: "ROLE_USER", messageId: "msg-2",
                   metadata: { skillId: "quote_event" }, parts: [{ text: "Cotízame" }] }
      }, context: context)

      expect(task.dig(:status, :state)).to eq("TASK_STATE_INPUT_REQUIRED")
      expect(task.dig(:status, :message, :parts, 0, :text)).to include("budget")
    end

    it "isolates task lookup by tenant" do
      task = described_class.send_message({
        message: { role: "ROLE_USER", messageId: "msg-3",
                   metadata: { skillId: "quote_event" }, parts: [{ data: { budget: 1 } }] }
      }, context: context)

      other = Agentkit::Context.new(tenant_key: "vendor-other")
      expect { described_class.get_task(task[:id], context: other) }
        .to raise_error(described_class::ProtocolError, /not found/)
    end
  end

  describe "signed Agent Cards" do
    it "signs and verifies a card with RS256" do
      key = OpenSSL::PKey::RSA.generate(1024)
      Agentkit.config.a2a.signing_key = key
      Agentkit.config.a2a.signing_key_id = "provider-2026-01"
      Agentkit.config.a2a.trusted_keys = { "provider-2026-01" => key.public_key }

      card = described_class.card(context: context)

      expect(card[:signatures].length).to eq(1)
      expect(described_class::CardSigner.verify!(card, policy: :required)).to be(true)
    end

    it "rejects unsigned cards when verification is required" do
      expect { described_class::CardSigner.verify!({ name: "Unsigned" }, policy: :required) }
        .to raise_error(described_class::ProtocolError, /unsigned/)
    end
  end

  describe Agentkit::A2A::V1::Client do
    it "sends the version, media type and bearer credential" do
      captured = nil
      transport = lambda do |verb, url, body, headers|
        captured = [verb, url, body, headers]
        { "task" => { "id" => "task-1" } }
      end
      client = described_class.new(base_url: "https://peer.test", token: "secret",
                                   transport: transport)
      client.send_message({ role: "ROLE_USER", messageId: "m", parts: [{ text: "hola" }] })

      expect(captured[0..1]).to eq([:post, "https://peer.test/agentkit/a2a/message:send"])
      expect(captured[3]).to include("A2A-Version" => "1.0", "Authorization" => "Bearer secret")
    end

    it "replaces transport exceptions with a generic correlated error" do
      transport = ->(*) { raise "connection failed at /private/app.rb" }
      client = described_class.new(base_url: "https://peer.test", transport: transport)

      expect do
        client.send_message({ role: "ROLE_USER", messageId: "m", parts: [] })
      end.to raise_error(Agentkit::A2A::V1::ProtocolError,
                         /peer request failed \(request_id=/) do |error|
        expect(error.message).not_to include("/private/app.rb")
      end
    end
  end
end
