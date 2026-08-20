# frozen_string_literal: true

module Agentkit
  module TeamMemory
    # Access Control Layer (ACL) for governing team memory assets.
    module ACL
      class << self
        # Check if an asset is accessible by an agent within a given team context.
        #
        # @param asset      [MemoryAsset, Hash, Object] The asset to evaluate
        # @param agent_name [String, Symbol, nil]       Name of the accessing agent
        # @param team_id    [Integer, nil]              ID of the team context
        # @param owner_id   [Integer, nil]              ID of the user/owner context
        # @return           [Boolean]
        def accessible?(asset, agent_name: nil, team_id: nil, owner_id: nil,
                        tenant_key: nil, action: :read)
          visibility  = extract_field(asset, :visibility).to_s
          asset_team  = extract_field(asset, :team_id)
          asset_owner = extract_field(asset, :owner_id)
          bindings    = Array(extract_field(asset, :bindings))
          asset_tenant = extract_field(asset, :tenant_key)

          return false unless %i[read use update bind export activate].include?(action.to_sym)
          effective_tenant = tenant_key || Context.current&.tenant_key
          return false if Agentkit.config.multi_tenant && effective_tenant.to_s.empty?
          return false if effective_tenant && asset_tenant.to_s != effective_tenant.to_s

          case visibility
          when "private"
            owner_id && asset_owner && owner_id.to_s == asset_owner.to_s
          when "team"
            !asset_team.nil? && !team_id.nil? && asset_team.to_s == team_id.to_s
          when "restricted"
            !agent_name.nil? && bindings.any? && bindings.include?(agent_name.to_s)
          when "agent"
            !agent_name.nil? && bindings.any? && bindings.include?(agent_name.to_s)
          else
            false
          end
        end

        # Filter a list of assets based on ACL rules.
        def filter(assets, agent_name: nil, team_id: nil, owner_id: nil, tenant_key: nil, action: :read)
          Array(assets).select do |asset|
            accessible?(asset, agent_name: agent_name, team_id: team_id, owner_id: owner_id,
                        tenant_key: tenant_key, action: action)
          end
        end

        private

        def extract_field(object, key)
          if object.is_a?(Hash)
            object[key] || object[key.to_s]
          elsif object.respond_to?(key)
            object.public_send(key)
          end
        end
      end
    end
  end
end
