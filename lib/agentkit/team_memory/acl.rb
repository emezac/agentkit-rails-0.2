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
        def accessible?(asset, agent_name: nil, team_id: nil, owner_id: nil)
          visibility  = extract_field(asset, :visibility).to_s
          asset_team  = extract_field(asset, :team_id)
          asset_owner = extract_field(asset, :owner_id)
          bindings    = Array(extract_field(asset, :bindings))

          case visibility
          when "private"
            return true if owner_id && asset_owner && owner_id.to_i == asset_owner.to_i
            return true if agent_name && bindings.include?(agent_name.to_s)

            false
          when "team"
            return true if asset_team.nil?
            return true if team_id && asset_team.to_i == team_id.to_i

            false
          when "restricted"
            return false if agent_name.nil?

            bindings.include?(agent_name.to_s)
          when "agent", "public"
            true
          else
            asset_team.nil? || (team_id && asset_team.to_i == team_id.to_i)
          end
        end

        # Filter a list of assets based on ACL rules.
        def filter(assets, agent_name: nil, team_id: nil, owner_id: nil)
          Array(assets).select do |asset|
            accessible?(asset, agent_name: agent_name, team_id: team_id, owner_id: owner_id)
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
