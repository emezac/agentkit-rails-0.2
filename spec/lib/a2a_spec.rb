# frozen_string_literal: true

require "spec_helper"

# A2A rebuilt from what the projects actually shipped: `tres` proved JSON-RPC
# 2.0 + `.well-known/agent.json` + constant-time key comparison; `totallook`
# proved self-service registration and quota. The kernel's own v0.1 controller
# had zero uses because its card was a hardcoded list disconnected from what
# the app could do — here the card is generated from the Capability registry.
RSpec.describe Agentkit::A2A do
  let(:executed) { [] }

  before do
    Agentkit.config.a2a.enabled    = true
    Agentkit.config.a2a.secret_key = "secret-key-123456"
    Agentkit.config.a2a.base_url   = "https://acme.test"
    Agentkit.config.hitl.level     = :advisory

    sink = executed
    safe_flow = Class.new(Agentkit::Flow) do
      def self.name = "ImportContactsFlow"
      step(:run) { sink << :imported; "12 contactos" }
    end
    risky_flow = Class.new(Agentkit::Flow) do
      def self.name = "RefundFlow"
      step(:run) { sink << :refunded; "refunded" }
    end

    Agentkit::Capability.register :import_contacts do |c|
      c.title "Traer contactos"
      c.description "Importa contactos de una empresa"
      c.flow safe_flow
      c.inputs company: :string
      c.tags :sales
      c.risk :reversible
      c.hitl :auto
    end

    Agentkit::Capability.register :issue_refund do |c|
      c.title "Emitir reembolso"
      c.flow risky_flow
      c.inputs order_id: :integer
      c.risk :irreversible          # money: never remote-triggered without a human
    end

    Agentkit::Capability.register :needs_integration do |c|
      c.title "Requiere integración"
      c.flow safe_flow
      c.preconditions { |_setup, _ctx| false }
    end
  end

  def rpc(method, params = {}, key: "secret-key-123456")
    described_class.handle({ "jsonrpc" => "2.0", "id" => "1",
                             "method" => method, "params" => params }, key: key)
  end

  describe "the agent card is generated, not hand-written" do
    it "advertises exactly the capabilities the app can serve right now" do
      card = described_class.card

      ids = card[:skills].map { |s| s[:id] }
      expect(ids).to contain_exactly("import_contacts", "issue_refund")
      expect(ids).not_to include("needs_integration") # preconditions fail
      expect(card[:protocolVersion]).to eq("0.2")
      expect(card[:url]).to eq("https://acme.test/agentkit/a2a/rpc")
      expect(card[:authentication][:schemes]).to eq(["X-A2A-Key"])
    end

    it "tells peers the risk and whether a human will be involved" do
      card = described_class.card
      refund = card[:skills].find { |s| s[:id] == "issue_refund" }
      import = card[:skills].find { |s| s[:id] == "import_contacts" }

      expect(refund[:risk]).to eq("irreversible")
      expect(refund[:requiresHumanApproval]).to be(true)
      expect(import[:requiresHumanApproval]).to be(false)
    end

    it "honours an explicit expose list" do
      Agentkit.config.a2a.expose = [:import_contacts]
      expect(described_class.card[:skills].map { |s| s[:id] }).to eq(["import_contacts"])
    end

    it "honours a hide list" do
      Agentkit.config.a2a.hide = [:issue_refund]
      expect(described_class.card[:skills].map { |s| s[:id] }).to eq(["import_contacts"])
    end
  end

  describe "authentication" do
    it "rejects a missing or wrong key" do
      expect(rpc("capabilities.list", {}, key: nil).dig(:error, :code))
        .to eq(described_class::ERRORS[:unauthorized])
      expect(rpc("capabilities.list", {}, key: "wrong").dig(:error, :code))
        .to eq(described_class::ERRORS[:unauthorized])
    end

    it "compares keys in constant time regardless of length" do
      expect(described_class.secure_compare("abc", "abcd")).to be(false)
      expect(described_class.secure_compare("abcd", "abcd")).to be(true)
    end

    it "serves the card without a key" do
      expect(rpc("agent.card", {}, key: nil)[:result][:protocol]).to eq("A2A")
    end

    it "supports a key resolver for multi-tenant hosts" do
      acme = AgentkitSpecHelpers::Account.new(7, "Acme", "pro")
      Agentkit.config.a2a.key_resolver = ->(key) { key == "tenant-key" ? acme : nil }

      ctx = described_class.authenticate("tenant-key")
      expect(ctx.account).to eq(acme)
      expect(ctx.tenant_key).to eq("acct:7")
      expect(described_class.authenticate("nope")).to be_nil
    end
  end

  describe "invocation goes through the same rail as everything else" do
    it "executes a reversible, auto-gated capability" do
      response = rpc("capabilities.invoke",
                     { "capability" => "import_contacts", "inputs" => { "company" => "Acme" } })

      expect(response[:result][:status]).to eq("completed")
      expect(executed).to eq([:imported])
    end

    it "parks an irreversible capability in HITL instead of executing it" do
      response = rpc("capabilities.invoke",
                     { "capability" => "issue_refund", "inputs" => { "order_id" => 42 } })

      expect(response[:result][:status]).to eq("pending_approval")
      expect(response[:result][:taskId]).to start_with("suggestion:")
      expect(executed).to be_empty  # money did not move

      suggestion = Agentkit::HITL.pending.last
      expect(suggestion.priority).to eq("high")
      expect(suggestion.payload["via"]).to eq("a2a")
    end

    it "does not let force_sync bypass approval" do
      response = rpc("capabilities.invoke",
                     { "capability" => "issue_refund", "inputs" => { "order_id" => 42 },
                       "force_sync" => true })

      expect(response[:result][:status]).to eq("pending_approval")
      expect(executed).to be_empty
    end

    it "binds approval to the exact proposed arguments" do
      task = rpc("capabilities.invoke",
                 { "capability" => "issue_refund", "inputs" => { "order_id" => 42 } })[:result][:taskId]

      expect do
        Agentkit::HITL.approve(task.split(":").last.to_i, actor: "human:1",
                              final_payload: { "order_id" => 99, "via" => "a2a" })
      end.to raise_error(Agentkit::HITLError, /payload does not match/)
      expect(executed).to be_empty
    end

    it "namespaces idempotency by tenant" do
      params = { "capability" => "issue_refund", "inputs" => { "order_id" => 42 },
                 "idempotency_key" => "same-key" }
      a = Agentkit::Context.new(tenant_key: "a", principal: "peer:a")
      b = Agentkit::Context.new(tenant_key: "b", principal: "peer:b")

      first = described_class.handle({ "jsonrpc" => "2.0", "id" => "a", "method" => "capabilities.invoke", "params" => params }, context: a)
      second = described_class.handle({ "jsonrpc" => "2.0", "id" => "b", "method" => "capabilities.invoke", "params" => params }, context: b)

      expect(first[:result][:taskId]).not_to eq(second[:result][:taskId])
    end

    it "lets the caller poll the parked task until a human decides" do
      task = rpc("capabilities.invoke",
                 { "capability" => "issue_refund", "inputs" => { "order_id" => 42 } })[:result][:taskId]

      expect(rpc("tasks.get", { "taskId" => task })[:result][:status]).to eq("pending_approval")

      Agentkit::HITL.approve(task.split(":").last.to_i, actor: "human:1")
      expect(rpc("tasks.get", { "taskId" => task })[:result][:status]).to eq("completed")
    end

    it "reinstalls the approved executor after a process reload" do
      task = rpc("capabilities.invoke",
                 { "capability" => "issue_refund", "inputs" => { "order_id" => 42 } })[:result][:taskId]
      Agentkit::HITL.instance_variable_set(:@handlers, nil)
      Agentkit::A2A::Server.install_hitl_handler!("a2a:issue_refund")

      result = Agentkit::HITL.approve(task.split(":").last.to_i, actor: "human:1")

      expect(result.status).to eq("executed")
      expect(executed).to eq([:refunded])
    end

    it "blocks an irreversible effect when required audit evidence cannot persist" do
      task = rpc("capabilities.invoke",
                 { "capability" => "issue_refund", "inputs" => { "order_id" => 42 } })[:result][:taskId]
      allow(Agentkit::Audit.store).to receive(:append).and_raise("audit unavailable")

      result = Agentkit::HITL.approve(task.split(":").last.to_i, actor: "human:1")

      expect(result.status).to eq("execution_unknown")
      expect(executed).to be_empty
    end

    it "records the rejection so the peer learns why" do
      task = rpc("capabilities.invoke",
                 { "capability" => "issue_refund", "inputs" => { "order_id" => 1 } })[:result][:taskId]
      Agentkit::HITL.reject(task.split(":").last.to_i, actor: "human:1", code: :too_risky)

      expect(rpc("tasks.get", { "taskId" => task })[:result][:status]).to eq("rejected")
      expect(Agentkit::HITL.ledger.entries.last.rejection_code).to eq("too_risky")
    end

    it "refuses a capability that is not exposed" do
      Agentkit.config.a2a.hide = [:import_contacts]
      response = rpc("capabilities.invoke", { "capability" => "import_contacts", "inputs" => {} })

      expect(response.dig(:error, :code)).to eq(described_class::ERRORS[:forbidden])
    end

    it "validates required inputs" do
      response = rpc("capabilities.invoke", { "capability" => "import_contacts", "inputs" => {} })
      expect(response.dig(:error, :message)).to include("missing inputs: company")
    end

    it "refuses when preconditions do not hold" do
      Agentkit.config.a2a.expose = %i[needs_integration]
      response = rpc("capabilities.invoke", { "capability" => "needs_integration", "inputs" => {} })

      expect(response.dig(:error, :code)).to eq(described_class::ERRORS[:forbidden])
    end
  end

  describe "JSON-RPC conformance" do
    it "returns method_not_found for an unknown method" do
      expect(rpc("does.not.exist").dig(:error, :code))
        .to eq(described_class::ERRORS[:method_not_found])
    end

    it "rejects a malformed envelope" do
      response = described_class.handle("not a hash", key: "secret-key-123456")
      expect(response.dig(:error, :code)).to eq(described_class::ERRORS[:invalid_request])
    end

    it "echoes the request id" do
      expect(rpc("agent.card")[:id]).to eq("1")
    end

    it "maps errors onto sane HTTP statuses" do
      expect(described_class.http_status_for(rpc("capabilities.list", {}, key: nil))).to eq(401)
      expect(described_class.http_status_for(rpc("agent.card"))).to eq(200)
    end

    it "does not expose unexpected exception details" do
      allow(described_class::Server).to receive(:capabilities_list)
        .and_raise("SELECT * FROM secrets at /private/app.rb")

      response = rpc("capabilities.list")

      expect(response.dig(:error, :message)).to eq("internal error")
      expect(response.dig(:error, :data, :requestId)).to be_a(String)
      expect(response.to_s).not_to include("secrets", "/private/app.rb")
    end
  end

  describe "memory exposure is opt-in" do
    it "refuses by default" do
      expect(rpc("memory.recall", { "query" => "x" }).dig(:error, :code))
        .to eq(described_class::ERRORS[:forbidden])
    end

    it "never leaks imagined scenarios when enabled" do
      Agentkit.config.a2a.expose_memory = true
      Agentkit.config.memory.embedding.policy = :never
      Agentkit::Memory.store("hecho real sobre pagos", tags: %w[pagos])
      Agentkit::Memory.store("hipótesis sobre pagos", ontological_type: "imagined")

      memories = rpc("memory.recall", { "query" => "pagos", "mode" => "keyword" })[:result][:memories]

      expect(memories.map { |m| m[:ontological] }.uniq).to eq(["real"])
    end
  end

  describe "observability" do
    it "audits and instruments every request" do
      rpc("capabilities.list")

      expect(emitted("a2a.request").last.dims[:method]).to eq("capabilities.list")
      expect(Agentkit::Audit.entries(event_type: "a2a.capabilities.list")).not_to be_empty
    end
  end

  describe "outbound client" do
    it "speaks the same envelope to a peer" do
      captured = nil
      transport = lambda do |_verb, _url, body, headers|
        captured = [body, headers]
        { "jsonrpc" => "2.0", "id" => body["id"], "result" => { "status" => "completed" } }
      end

      client = described_class::Client.new(base_url: "https://peer.test", key: "k",
                                           transport: transport)
      response = client.invoke("capabilities.invoke",
                               { "capability" => "x", "inputs" => { "a" => 1 } })

      expect(response["result"]["status"]).to eq("completed")
      expect(captured[0]["jsonrpc"]).to eq("2.0")
      expect(captured[1]["X-A2A-Key"]).to eq("k")
      expect(emitted("a2a.outbound").last.dims[:peer]).to eq("https://peer.test")
    end

    it "polls a peer's parked approval until it resolves" do
      calls = 0
      transport = lambda do |_verb, _url, body, _headers|
        calls += 1
        if body["method"] == "capabilities.invoke"
          { "result" => { "status" => "pending_approval", "taskId" => "suggestion:9" } }
        else
          { "result" => { "status" => "completed" } }
        end
      end

      client = described_class::Client.new(base_url: "https://peer.test", transport: transport)
      result = client.call_capability(:issue_refund, { order_id: 1 },
                                      poll: true, interval: 0, max_wait: 5)

      expect(result["status"]).to eq("completed")
      expect(calls).to be >= 2
    end
  end
end
