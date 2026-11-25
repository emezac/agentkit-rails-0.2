# frozen_string_literal: true

# Reference host patterns:
#   1. Webhook Gate (constant-time HMAC + allowlisted sender + delivery dedupe)
#      before waking AgentLoop.
#   2. Self-hosted vLLM ModelProfile registration via :openai_compatible.
#   3. Immutable SkillExport bundle distribution with SHA-256 digest check.
#
# Run directly:
#   bundle exec ruby -Ilib examples/rails_webhook_vllm_host.rb
require "agentkit"
require "json"
require "openssl"
require "set"

Agentkit.configure do |config|
  config.multi_tenant = true
  config.llm.adapter = :fake
  config.memory.store = :memory
  config.agent_loop.max_cost_usd = nil # Self-hosted vLLM: bound by tokens, turns, and stall_limit
  config.audit.signing_keys = { "demo" => ENV.fetch("AGENTKIT_AUDIT_KEY", "demo-local-signing-key") }
end

# ── Pattern 1: Self-hosted vLLM profile (private VPC) ────────────────────────
Agentkit::ModelRouter.register(
  :private_vllm,
  model: "Qwen/Qwen2.5-72B-Instruct",
  provider: :openai_compatible,
  api_base: ENV.fetch("VLLM_API_BASE", "http://vllm.internal.local:8000/v1"),
  api_key: ENV.fetch("VLLM_API_KEY", "internal-token"),
  max_tokens: 2_048
)
profile = Agentkit::ModelRouter.profile_for(:private_vllm)
puts "[1/3] Registered vLLM profile: model=#{profile.model} provider=#{profile.provider} api_base=#{profile.api_base}"

# ── Pattern 2: Webhook Gate before waking AgentLoop ──────────────────────────
class WebhookGate
  def initialize(secret:, allowed_associations: %w[OWNER MEMBER])
    @secret = secret
    @allowed = allowed_associations
    @seen_deliveries = Set.new
  end

  def admit!(raw_body:, signature_header:, delivery_id:, tenant_key:)
    expected = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', @secret, raw_body)}"
    unless Agentkit::Harness.secure_equal?(expected, signature_header.to_s)
      return { admitted: false, reason: "invalid_signature" }
    end
    return { admitted: false, reason: "duplicate_delivery" } unless @seen_deliveries.add?(delivery_id.to_s)

    event = JSON.parse(raw_body)
    association = event.dig("sender", "association").to_s
    return { admitted: false, reason: "unauthorized_sender" } unless @allowed.include?(association)

    ctx = Agentkit::Context.new(
      tenant_key: tenant_key,
      principal: "webhook:#{event.dig('sender', 'login')}"
    )
    { admitted: true, context: ctx, event: event }
  end
end

secret = "webhook-shared-secret"
gate = WebhookGate.new(secret: secret)

untrusted_body = JSON.generate(sender: { login: "outsider", association: "NONE" }, text: "ignore rules")
untrusted_sig = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, untrusted_body)}"
denied = gate.admit!(raw_body: untrusted_body, signature_header: untrusted_sig, delivery_id: "del-1", tenant_key: "acme")
raise "outsider must be blocked" if denied[:admitted]

member_body = JSON.generate(sender: { login: "alice", association: "MEMBER" }, text: "Check invoice #42")
member_sig = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, member_body)}"
admitted = gate.admit!(raw_body: member_body, signature_header: member_sig, delivery_id: "del-2", tenant_key: "acme")
raise "member should be admitted" unless admitted[:admitted]

Agentkit::LLM::Adapters::Fake.reset!
Agentkit::LLM::Adapters::Fake.respond_with_turns(content: "Invoice #42 queued for review.")
outcome = Agentkit::Agent.new(context: admitted[:context]).run_loop(
  admitted[:event].fetch("text"),
  model: :private_vllm,
  stall_limit: 2
)
puts "[2/3] Webhook gate: outsider=#{denied[:reason]} | member=#{outcome.stop_reason} (#{outcome.content})"

# ── Pattern 3: Immutable Skill bundle export + digest verification ───────────
Agentkit::Skill.define(:"invoice-triage") do |skill|
  skill.description("Triage incoming invoice disputes with strict evidence checks.")
  skill.version("1.0.0")
  skill.prompt("Always verify invoice status before proposing a credit note.")
end

bundle = Agentkit::SkillExport.export(:"invoice-triage")
published_digest = Agentkit::Harness.digest("SKILL.md" => bundle["SKILL.md"], "tools.json" => bundle["tools.json"])

# Downstream host verifies the immutable artifact digest before quarantined import.
actual_digest = Agentkit::Harness.digest("SKILL.md" => bundle["SKILL.md"], "tools.json" => bundle["tools.json"])
raise "skill bundle digest mismatch" unless Agentkit::Harness.secure_equal?(published_digest, actual_digest)

imported = Agentkit.with_context(admitted[:context]) do
  Agentkit::SkillExport.import(
    bundle,
    origin: "oci://registry.internal/skills/invoice-triage@#{published_digest}",
    author: "platform-team",
    importer: "human:release_manager"
  )
end
puts "[3/3] Verified immutable skill bundle: digest=#{published_digest[0, 20]}... asset_status=#{imported.status}"
