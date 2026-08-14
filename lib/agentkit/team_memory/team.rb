# frozen_string_literal: true

module Agentkit
  module TeamMemory
    # Team domain entity representing a group of agents sharing governed memory assets.
    class Team
      attr_reader :id, :name, :description, :owner_id, :account_id, :metadata

      class << self
        def registry
          @registry ||= {}
        end

        def create(name:, description: nil, owner_id: nil, account_id: nil, metadata: {})
          name_str = name.to_s
          if defined?(Agentkit::TeamRecord) && TeamMemory.ar_available?(Agentkit::TeamRecord)
            rec = Agentkit::TeamRecord.create!(
              name: name_str, description: description, owner_id: owner_id,
              account_id: account_id, metadata: metadata
            )
            from_record(rec)
          else
            team = new(id: registry.size + 1, name: name_str, description: description,
                       owner_id: owner_id, account_id: account_id, metadata: metadata)
            registry[name_str] = team
            team
          end
        end

        def find_by_name(name)
          name_str = name.to_s
          if defined?(Agentkit::TeamRecord) && TeamMemory.ar_available?(Agentkit::TeamRecord)
            rec = Agentkit::TeamRecord.find_by(name: name_str)
            rec ? from_record(rec) : nil
          else
            registry[name_str]
          end
        end

        def find_or_create(name, **kwargs)
          find_by_name(name) || create(name: name, **kwargs)
        end

        def reset!
          @registry = {}
        end

        private

        def from_record(rec)
          new(
            id: rec.id, name: rec.name, description: rec.description,
            owner_id: rec.owner_id, account_id: rec.account_id, metadata: rec.metadata
          )
        end
      end

      def initialize(id: nil, name:, description: nil, owner_id: nil, account_id: nil, metadata: {})
        @id          = id
        @name        = name.to_s
        @description = description
        @owner_id    = owner_id
        @account_id  = account_id
        @metadata    = metadata || {}
      end

      def assets
        AssetStore.list_for_team(id || name)
      end

      def equip(agent)
        TeamMemory.equip(agent: agent, team: name)
      end

      def to_h
        {
          id: id, name: name, description: description,
          owner_id: owner_id, account_id: account_id, metadata: metadata
        }
      end
    end
  end
end
