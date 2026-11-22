# frozen_string_literal: true

# Reference example: Governed Knowledge Factory with AgentKit Rails.
#
# Shows how to compose existing AgentKit primitives into a closed-loop
# knowledge factory without allowing runtime or curator agents to mutate
# production skills or wikis without quarantine and human review:
#
#   1. Runtime AgentLoop uses live data tools + opt-in `flag_knowledge_gap`
#      to report missing/stale/contradictory knowledge as untrusted claims.
#   2. Offline curator reads open gaps via `Memory::KnowledgeGaps.list` and
#      extracts a candidate skill into quarantine (`TeamMemory::SkillExtractor`).
#   3. An independent authenticated human reviews and activates the skill
#      (`review_and_activate!`) and resolves the gap (`KnowledgeGaps.resolve!`).
#
# Run directly:
#   ruby -Ilib examples/governed_knowledge_factory.rb
require "agentkit"

Agentkit.configure do |config|
  config.multi_tenant = true
  config.llm.adapter = :fake
  config.memory.store = :memory
  config.audit.signing_keys = { "demo" => ENV.fetch("AGENTKIT_AUDIT_KEY", "demo-local-signing-key") }
end

Agentkit::LLM::Adapters::Fake.reset!

# 1. Runtime execution: an agent prepares a revenue report, discovers a renamed
#    column in live data, and flags the stale guidance without mutating skills.
runtime_ctx = Agentkit::Context.new(tenant_key: "acme", principal: "agent:revenue_reporter")

bq_schema_tool = Agentkit::ToolContract.new(
  name: :inspect_revenue_schema,
  description: "Read current live column names from the revenue warehouse table",
  risk: :read,
  effect: :read_only,
  callable: -> { { table: "revenue_daily", columns: %w[date account_id arr_net] } }
)

Agentkit::LLM::Adapters::Fake.respond_with_turns(
  { tool_calls: [{ "id" => "call-1", "name" => "inspect_revenue_schema", "arguments" => {} }] },
  {
    tool_calls: [{
      "id" => "call-2",
      "name" => "flag_knowledge_gap",
      "arguments" => {
        "kind" => "stale",
        "subject" => "bigquery/revenue_daily",
        "summary" => "Skill references arr_v1, but live schema now uses arr_net.",
        "suggested_update" => "Update revenue_report skill to query arr_net."
      }
    }]
  },
  { content: "Drafted Q4 revenue report using arr_net and flagged stale schema guidance." }
)

agent = Agentkit::Agent.new(context: runtime_ctx)
outcome = agent.run_loop(
  "Prepare the Q4 revenue report.",
  tools: [bq_schema_tool, Agentkit::Memory::KnowledgeGaps.tool],
  eager_tools: %i[inspect_revenue_schema flag_knowledge_gap]
)

puts "[1/3] Runtime loop: status=#{outcome.stop_reason} | #{outcome.content}"

# 2. Offline curation: reads open gaps and extracts a quarantined skill candidate
#    from the reviewed interaction/guidance. Nothing is active in production yet.
curator_ctx = Agentkit::Context.new(tenant_key: "acme", principal: "agent:curator")
open_gaps = Agentkit::Memory::KnowledgeGaps.list(status: "open", context: curator_ctx)
gap = open_gaps.first
puts "[2/3] Open gap flagged: id=#{gap.id} kind=#{gap.metadata['kind']} subject=#{gap.metadata['subject']} untrusted=#{gap.metadata['untrusted_claim']}"

candidate_skill = Agentkit.with_context(curator_ctx) do
  Agentkit::TeamMemory::SkillExtractor.extract(
    name: "revenue_report_v2",
    conversation: [
      { role: "user", content: "Trigger: quarterly revenue report" },
      { role: "assistant", content: "Step 1: Inspect live revenue_daily schema and query arr_net. Step 2: Apply the official company header." }
    ]
  )
end
puts "[2/3] Candidate skill extracted: name=#{candidate_skill.name} status=#{candidate_skill.status} (quarantined)"

# 3. Independent human review: activates the quarantined skill and resolves the gap.
reviewer_ctx = Agentkit::Context.new(tenant_key: "acme", principal: "human:finance_lead")
activated = Agentkit.with_context(reviewer_ctx) do
  Agentkit::TeamMemory::SkillExtractor.review_and_activate!(
    candidate_skill,
    actor: "human:finance_lead",
    authorize: ->(_asset, actor) { actor == "human:finance_lead" }
  )
end

resolved = Agentkit::Memory::KnowledgeGaps.resolve!(
  id: gap.id,
  actor: "human:finance_lead",
  authorize: ->(_gap, actor, _ctx) { actor == "human:finance_lead" },
  resolution: "Activated revenue_report_v2 using arr_net after verifying warehouse schema.",
  context: reviewer_ctx
)

puts "[3/3] Human review complete: skill_status=#{activated.status} gap_status=#{resolved['status']}"
