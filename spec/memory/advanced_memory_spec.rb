# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Advanced Memory Improvements (Épica 3)" do
  before do
    Agentkit::Flow.test_mode!
    Agentkit.reset!
    Agentkit.config.memory.store = :memory
  end

  describe Agentkit::Memory::Layers do
    it "normalizes layer levels and names correctly" do
      expect(described_class.normalize_layer("l2")).to eq(2)
      expect(described_class.name_for(1)).to include("L1: Memory Atom")
      expect(described_class.tag_for("l3")).to eq("layer:l3")
    end
  end

  describe Agentkit::Memory::ColdStart do
    it "imports historical conversations and extracts L1 atoms" do
      history = [
        { "content" => "User prefers email notifications.", "timestamp" => "2026-01-01T10:00:00Z" },
        { "content" => "Security rule: enforce strong passwords.", "timestamp" => "2026-01-02T10:00:00Z" }
      ]

      result = described_class.import(history, default_agent: "LegacyApp")

      expect(result[:imported]).to eq(2)
      expect(result[:atoms]).to be >= 2

      recalled = Agentkit::Memory.recall("notifications")
      expect(recalled).not_to be_empty
    end
  end

  describe Agentkit::Memory::CustomPrompts do
    it "registers and renders customized extraction templates with context variables" do
      described_class.register(
        "tenant_acme",
        prompt_type: "extraction",
        template: "Extract facts for tenant {tenant}: {input}",
        version: "2.1.0"
      )

      rendered, version = described_class.render(
        "tenant_acme",
        prompt_type: "extraction",
        default_template: "Default prompt",
        context: { tenant: "AcmeCorp", input: "User requested refund." }
      )

      expect(version).to eq("2.1.0")
      expect(rendered).to include("Extract facts for tenant AcmeCorp: User requested refund.")
    end
  end

  describe "Time-filtered Memory Recall" do
    it "filters recalled memories by since and until timestamps" do
      t1 = Time.now - 3600
      t2 = Time.now - 1800

      mem1 = Agentkit::Memory.store("First observation", tags: ["time_test"])
      mem1.created_at = t1

      mem2 = Agentkit::Memory.store("Second observation", tags: ["time_test"])
      mem2.created_at = t2

      recalled_since = Agentkit::Memory.recall("observation", since: Time.now - 2000)
      expect(recalled_since.map(&:content)).to include("Second observation")
      expect(recalled_since.map(&:content)).not_to include("First observation")
    end
  end

  describe "Interactive mem: Chat Commands" do
    it "intercepts mem: commands in Agentkit::Chat.say" do
      turn = Agentkit::Chat.say("mem:status")
      expect(turn.message).to include("Estado de Memoria:")

      help_turn = Agentkit::Chat.say("mem:help")
      expect(help_turn.message).to include("Comandos de memoria disponibles")
    end
  end

  describe Agentkit::SkillExport do
    it "exports a skill to a markdown bundle and imports it back" do
      skill = Agentkit::Skill.define(:"test-export-skill") do |s|
        s.description("Reviews a supplied brief: use for negotiation preparation, not sending messages.")
        s.version("2.3.0")
        s.prompt("## Test Skill Prompt")
      end

      bundle = described_class.export(skill)

      expect(bundle["SKILL.md"]).to include("## Test Skill Prompt")
      expect(bundle["SKILL.md"]).to include("agentkit-version: 2.3.0")

      Agentkit::SkillRegistry.reset!
      imported = described_class.import(bundle)
      expect(imported.name).to eq("test-export-skill")
      expect(imported.status).to eq("quarantined")
      expect(Agentkit::SkillRegistry.registered?(:"test-export-skill")).to be(false)

      proposal = Agentkit::HITL.pending(type: "skill_activation").last
      Agentkit::HITL.approve(proposal.id, actor: "human:reviewer")

      activated = Agentkit::SkillRegistry.load_skill(:"test-export-skill")
      expect(activated.description).to eq(skill.description)
      expect(activated.version).to eq("2.3.0")
      expect(Agentkit::TeamMemory::AssetStore.find(imported.id).status).to eq("active")
    end

    it "can still activate a quarantined legacy asset without a description" do
      legacy = Agentkit::TeamMemory.create_asset(
        asset_type: "skill", name: "LegacySkill", version: "1.0.0",
        status: "quarantined", visibility: "restricted",
        content: { "prompt_fragment" => "Legacy procedure", "version" => "1.0.0", "digest" => "legacy" }
      )

      activated = described_class.activate(legacy, approver: "human:reviewer")

      expect(activated.prompt).to eq("Legacy procedure")
      expect(activated.description).to eq("")
      expect(Agentkit::TeamMemory::AssetStore.find(legacy.id).status).to eq("active")
    end
  end
end
