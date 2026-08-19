# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

class SecurityAnalystAgent < Agentkit::Agent
  belongs_to_team "SecurityTeam"

  def call(input)
    assets = load_team_assets
    Agentkit::Result.ok({ assets: assets })
  end
end

RSpec.describe Agentkit::TeamMemory do
  before do
    Agentkit::Flow.test_mode!
    Agentkit.reset!
    Agentkit.config.memory.store = :memory
  end

  describe "ACL Rules" do
    let(:team) { described_class.create_team(name: "Engineering") }

    it "permits team members to access team visibility assets" do
      asset = described_class.create_asset(
        asset_type: "chat_memory",
        name: "architecture_decisions",
        team_id: team.id,
        visibility: "team"
      )

      expect(described_class::ACL.accessible?(asset, team_id: team.id)).to be true
      expect(described_class::ACL.accessible?(asset, team_id: 999)).to be false
    end

    it "restricts private assets to matching owners" do
      asset = described_class.create_asset(
        asset_type: "chat_memory",
        name: "private_key_notes",
        team_id: team.id,
        visibility: "private",
        owner_id: 42
      )

      expect(described_class::ACL.accessible?(asset, owner_id: 42)).to be true
      expect(described_class::ACL.accessible?(asset, owner_id: 99)).to be false
    end

    it "restricts restricted assets to explicitly bound agents" do
      asset = described_class.create_asset(
        asset_type: "skill",
        name: "deploy_production",
        team_id: team.id,
        visibility: "restricted",
        bindings: ["DeployerAgent"]
      )

      expect(described_class::ACL.accessible?(asset, agent_name: "DeployerAgent")).to be true
      expect(described_class::ACL.accessible?(asset, agent_name: "ReaderAgent")).to be false
    end
  end

  describe "Wiki Asset Engine" do
    it "creates pages, parses wikilinks, and searches content" do
      wiki_asset = described_class::Wiki.create_wiki(name: "SecurityDocs")
      page1 = described_class::Wiki.add_page(
        wiki_asset,
        title: "OAuth2 Architecture",
        content: "OAuth2 authentication details. See also [[PKCE Enforcement]] and [[JWT Validation]]."
      )

      expect(page1.links).to contain_exactly("PKCE Enforcement", "JWT Validation")

      results = described_class::Wiki.search_pages(wiki_asset, "OAuth2 authentication")
      expect(results.first.title).to eq("OAuth2 Architecture")
    end
  end

  describe "CodeGraph Static Analysis" do
    it "indexes Ruby code, registers symbols, and performs impact analysis" do
      sample_file = File.join(Dir.tmpdir, "sample_service.rb")
      File.write(sample_file, <<~RUBY)
        module Payment
          class Charger
            def process_charge
              puts "Charging"
            end
          end
        end
      RUBY

      graph_asset = described_class::CodeGraph.create_graph(name: "PaymentRepo")
      described_class::CodeGraph.index_files(graph_asset, [sample_file])

      symbols = described_class::CodeGraph.all_symbols(graph_asset)
      names = symbols.map(&:name)

      expect(names).to include("Payment", "Charger", "process_charge")

      impact = described_class::CodeGraph.impact_analysis(graph_asset, "process_charge")
      expect(impact.map(&:name)).to include("process_charge")
    ensure
      File.delete(sample_file) if sample_file && File.exist?(sample_file)
    end
  end

  describe "SkillExtractor" do
    it "extracts reusable skills from conversation transcripts" do
      transcript = [
        "User: How do I deploy the API?",
        "Agent: Step 1: Run specs. Step 2: Push container. Step 3: Trigger rollback on failure."
      ]

      asset = described_class::SkillExtractor.extract(
        conversation: transcript,
        name: "DeployAPISkill"
      )

      expect(asset.asset_type).to eq("skill")
      expect(asset.content["steps"].size).to be >= 3
      expect(asset.content["prompt_fragment"]).to include("Run specs")
    end
  end

  describe "LayeredPipeline (L0 -> L1 -> L2 -> L3)" do
    it "progresses raw logs into L1 atoms, L2 scenes, and L3 persona skills" do
      raw_logs = [
        "User prefers dark mode UI.",
        "Team decided to mandate 2FA for admin roles.",
        "Security rule: passwords must expire in 90 days."
      ]

      l1_atoms = described_class::LayeredPipeline.process_l0_to_l1(raw_logs, source_agent: "AuditAgent")
      expect(l1_atoms.size).to eq(3)

      l2_scene = described_class::LayeredPipeline.process_l1_to_l2(l1_atoms, scene_name: "SecurityBasics")
      expect(l2_scene.asset_type).to eq("chat_memory")

      l3_persona = described_class::LayeredPipeline.process_l2_to_l3([l2_scene], persona_name: "SecurityExpertSkill")
      expect(l3_persona.asset_type).to eq("skill")
    end
  end

  describe "Agent Integration (AgentConcern)" do
    it "loads team assets and shares new skills" do
      agent = SecurityAnalystAgent.new
      agent.join_team("SecurityTeam")

      agent.share_skill("ScanVulnerabilities", prompt_fragment: "Scan all dependencies using SAST.")
      assets = agent.load_team_assets

      expect(assets.map(&:name)).to include("ScanVulnerabilities")
    end
  end


  describe "tenant isolation" do
    it "keeps teams and identically named assets inside their tenant" do
      tenant_a = Agentkit::Context.new(tenant_key: "team-tenant:a")
      tenant_b = Agentkit::Context.new(tenant_key: "team-tenant:b")

      team_a = Agentkit.with_context(tenant_a) { described_class.create_team(name: "Operations") }
      team_b = Agentkit.with_context(tenant_b) { described_class.create_team(name: "Operations") }
      Agentkit.with_context(tenant_a) do
        described_class.create_asset(asset_type: "skill", name: "Deploy", team_id: team_a.id)
      end
      Agentkit.with_context(tenant_b) do
        described_class.create_asset(asset_type: "skill", name: "Deploy", team_id: team_b.id)
      end

      assets_a = Agentkit.with_context(tenant_a) { described_class.load_assets(team: "Operations") }
      assets_b = Agentkit.with_context(tenant_b) { described_class.load_assets(team: "Operations") }

      expect(team_a.tenant_key).to eq("team-tenant:a")
      expect(team_b.tenant_key).to eq("team-tenant:b")
      expect(assets_a.map(&:tenant_key)).to contain_exactly("team-tenant:a")
      expect(assets_b.map(&:tenant_key)).to contain_exactly("team-tenant:b")
    end

    it "rejects unscoped operations when multi-tenancy is enabled" do
      Agentkit.config.multi_tenant = true

      expect { described_class.create_team(name: "Unscoped") }
        .to raise_error(Agentkit::ConfigurationError, /requires a tenant_key/)
    ensure
      Agentkit.config.multi_tenant = false
    end


    it "rejects an asset linked to another tenant's team" do
      tenant_a = Agentkit::Context.new(tenant_key: "team-owner:a")
      tenant_b = Agentkit::Context.new(tenant_key: "team-owner:b")
      team_a = Agentkit.with_context(tenant_a) { described_class.create_team(name: "Private Operations") }

      expect do
        Agentkit.with_context(tenant_b) do
          described_class.create_asset(asset_type: "skill", name: "CrossTenant", team_id: team_a.id)
        end
      end.to raise_error(Agentkit::ConfigurationError, /does not belong to tenant/)
    end


    it "enforces the same boundary through specialized asset stores" do
      tenant_a = Agentkit::Context.new(tenant_key: "wiki-owner:a")
      tenant_b = Agentkit::Context.new(tenant_key: "wiki-owner:b")
      team_a = Agentkit.with_context(tenant_a) { described_class.create_team(name: "Private Wiki") }

      expect do
        Agentkit.with_context(tenant_b) do
          described_class::Wiki.create_wiki(name: "CrossTenantWiki", team_id: team_a.id)
        end
      end.to raise_error(Agentkit::ConfigurationError, /does not belong to tenant/)
    end
  end
end
