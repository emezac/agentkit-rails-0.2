# frozen_string_literal: true

require_relative "team_memory/acl"
require_relative "team_memory/team"
require_relative "team_memory/asset"
require_relative "team_memory/wiki"
require_relative "team_memory/code_graph"
require_relative "team_memory/skill_extractor"
require_relative "team_memory/layered_pipeline"

module Agentkit
  # Team Memory Hub (TencentDB Agent Memory implementation for AgentKit).
  # Governs team-level memory assets: ChatMemory, Skill, Wiki, CodeGraph with ACL rules.
  module TeamMemory
    class << self
      # Create or find a team
      def create_team(name:, description: nil, owner_id: nil, account_id: nil, metadata: {})
        Team.create(
          name: name, description: description, owner_id: owner_id,
          account_id: account_id, metadata: metadata
        )
      end

      def find_team(name)
        Team.find_by_name(name)
      end

      # Create a new governed memory asset
      def create_asset(asset_type:, name:, team_id: nil, visibility: "team", owner_id: nil,
                       version: "1.0.0", status: "ready", content: {}, bindings: [])
        AssetStore.create(
          asset_type: asset_type, name: name, team_id: team_id,
          visibility: visibility, owner_id: owner_id, version: version,
          status: status, content: content, bindings: bindings
        )
      end

      # Bind an asset explicitly to an agent or entity
      def bind_asset(asset_or_name, agent_name:, priority: 50)
        asset = asset_or_name.is_a?(Asset) ? asset_or_name : AssetStore.find_by_name(asset_or_name)
        return nil if asset.nil?

        if defined?(Agentkit::AssetBindingRecord) && ar_available?(Agentkit::AssetBindingRecord) && asset.id
          Agentkit::AssetBindingRecord.create!(
            asset_id: asset.id,
            agent_name: agent_name.to_s,
            priority: priority
          )
        end

        # Update bindings list on asset
        updated_bindings = (asset.bindings + [agent_name.to_s]).uniq
        asset
      end

      # Load all accessible assets for an agent within a team context
      def load_assets(team: nil, agent_name: nil, owner_id: nil, asset_type: nil)
        team_obj = team ? (team.is_a?(Team) ? team : find_team(team)) : nil
        team_id  = team_obj&.id || (team.is_a?(Numeric) ? team : nil)

        all_assets = if team_id
                       AssetStore.list_for_team(team_id, asset_type: asset_type)
                     else
                       AssetStore.all
                     end

        ACL.filter(all_assets, agent_name: agent_name, team_id: team_id, owner_id: owner_id)
      end

      # Equip an agent instance with accessible team assets (skills, wiki excerpts, context)
      def equip(agent:, team: nil, owner_id: nil)
        agent_name = agent.class.name
        assets = load_assets(team: team, agent_name: agent_name, owner_id: owner_id)

        # Inject skill assets into SkillRegistry
        assets.select { |a| a.asset_type == "skill" }.each do |skill_asset|
          if defined?(Agentkit::Skill) && skill_asset.content["prompt_fragment"]
            Agentkit::Skill.define(skill_asset.name) do |s|
              s.prompt(skill_asset.content["prompt_fragment"])
            end
          end
        end

        assets
      end

      def ar_available?(record_class)
        return false unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?
        return false unless record_class.is_a?(Class)

        record_class.table_exists?
      rescue StandardError
        false
      end

      def reset!
        Team.reset!
        AssetStore.reset!
        Wiki.reset!
        CodeGraph.reset!
      end
    end
  end
end
