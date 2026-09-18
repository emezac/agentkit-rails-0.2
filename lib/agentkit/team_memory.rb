# frozen_string_literal: true

require_relative "team_memory/acl"
require_relative "team_memory/team"
require_relative "team_memory/asset"
require_relative "team_memory/graph"
require_relative "team_memory/spreading_activation"
require_relative "team_memory/evaluation"
require_relative "team_memory/visualization"
require_relative "team_memory/wiki"
require_relative "team_memory/code_graph"
require_relative "team_memory/skill_extractor"
require_relative "team_memory/layered_pipeline"

module Agentkit
  # Team Memory Hub (TencentDB Agent Memory implementation for AgentKit).
  # Governs team-level memory assets: ChatMemory, Skill, Wiki, CodeGraph with ACL rules.
  module TeamMemory
    GLOBAL_TENANT_KEY = "__global__"

    class << self
      # Create or find a team
      def create_team(name:, description: nil, owner_id: nil, account_id: nil, tenant_key: nil, metadata: {})
        scope = resolve_tenant_scope(tenant_key: tenant_key, account_id: account_id)
        Team.create(
          name: name, description: description, owner_id: owner_id,
          metadata: metadata, **scope
        )
      end

      def find_team(name, tenant_key: nil, account_id: nil)
        scope = resolve_tenant_scope(tenant_key: tenant_key, account_id: account_id)
        Team.find_by_name(name, **scope)
      end

      # Create a new governed memory asset
      def create_asset(asset_type:, name:, team_id: nil, visibility: "team", owner_id: nil,
                       version: "1.0.0", status: "ready", content: {}, bindings: [],
                       tenant_key: nil, account_id: nil)
        scope = resolve_tenant_scope(tenant_key: tenant_key, account_id: account_id)
        validate_team_scope!(team_id, **scope) if team_id
        AssetStore.create(
          asset_type: asset_type, name: name, team_id: team_id,
          visibility: visibility, owner_id: owner_id, version: version,
          status: status, content: content, bindings: bindings, **scope
        )
      end

      # Bind an asset explicitly to an agent or entity
      def bind_asset(asset_or_name, agent_name:, priority: 50, tenant_key: nil, account_id: nil)
        scope = resolve_tenant_scope(tenant_key: tenant_key, account_id: account_id)
        asset = asset_or_name.is_a?(Asset) ? asset_or_name : AssetStore.find_by_name(asset_or_name, **scope)
        return nil if asset.nil?
        if asset.tenant_key.to_s != scope[:tenant_key].to_s
          raise ConfigurationError, "Cannot bind a TeamMemory asset from another tenant"
        end

        if defined?(Agentkit::AssetBindingRecord) && ar_available?(Agentkit::AssetBindingRecord) && asset.id
          Agentkit::AssetBindingRecord.create!(
            asset_id: asset.id,
            agent_name: agent_name.to_s,
            priority: priority,
            tenant_key: asset.tenant_key,
            account_id: asset.account_id
          )
        end

        # Update bindings list on asset
        updated_bindings = (asset.bindings + [agent_name.to_s]).uniq
        asset
      end

      # Load all accessible assets for an agent within a team context
      def load_assets(team: nil, agent_name: nil, owner_id: nil, asset_type: nil,
                      tenant_key: nil, account_id: nil)
        scope = resolve_tenant_scope(tenant_key: tenant_key, account_id: account_id)
        if team.is_a?(Team) && team.tenant_key.to_s != scope[:tenant_key].to_s
          raise ConfigurationError, "Cannot load TeamMemory assets from another tenant"
        end
        team_obj = team ? (team.is_a?(Team) ? team : find_team(team, **scope)) : nil
        team_id  = team_obj&.id || (team.is_a?(Numeric) ? team : nil)

        all_assets = if team_id
                       AssetStore.list_for_team(team_id, asset_type: asset_type, **scope)
                     else
                       AssetStore.all(**scope)
                     end

        ACL.filter(all_assets, agent_name: agent_name, team_id: team_id, owner_id: owner_id,
                   tenant_key: scope[:tenant_key])
      end

      # Equip an agent instance with accessible team assets (skills, wiki excerpts, context)
      def equip(agent:, team: nil, owner_id: nil)
        agent_name = agent.class.name
        assets = load_assets(team: team, agent_name: agent_name, owner_id: owner_id)

        # Inject skill assets into SkillRegistry
        assets.select { |a| a.asset_type == "skill" && a.status == "active" }.each do |skill_asset|
          if defined?(Agentkit::Skill) && skill_asset.content["prompt_fragment"]
            Agentkit::Skill.define(skill_asset.name) do |s|
              s.prompt(skill_asset.content["prompt_fragment"])
            end
          end
        end

        assets
      end

      def ar_available?(record_class)
        return false unless Agentkit.config.team_memory.store.to_sym == :active_record
        return false unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?
        return false unless record_class.is_a?(Class)

        record_class.table_exists?
      rescue StandardError
        false
      end

      def resolve_tenant_scope(tenant_key: nil, account_id: nil)
        context = Context.resolve
        resolved_key = tenant_key || context.tenant_key
        if Agentkit.config.multi_tenant && resolved_key.nil?
          raise ConfigurationError, "TeamMemory requires a tenant_key when multi_tenant is enabled"
        end

        resolved_account_id = account_id || id_of(context.account)
        { tenant_key: resolved_key || GLOBAL_TENANT_KEY, account_id: resolved_account_id }
      end

      def reset!
        Team.reset!
        AssetStore.reset!
        Wiki.reset!
        CodeGraph.reset!
        Graph.reset!
        Visualization.reset!
      end

      private

      def validate_team_scope!(team_id, tenant_key:, account_id: nil)
        return if Team.find_by_id(team_id, tenant_key: tenant_key, account_id: account_id)

        raise ConfigurationError, "Team #{team_id} does not belong to tenant #{tenant_key}"
      end

      def id_of(value)
        value.respond_to?(:id) ? value.id : value
      end
    end
  end
end
