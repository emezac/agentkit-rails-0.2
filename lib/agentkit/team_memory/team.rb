# frozen_string_literal: true

module Agentkit
  module TeamMemory
    # Team domain entity representing a group of agents sharing governed memory assets.
    class Team
      attr_reader :id, :name, :description, :owner_id, :account_id, :tenant_key, :metadata

      class << self
        def registry
          @registry ||= {}
        end

        def create(name:, description: nil, owner_id: nil, account_id: nil,
                   tenant_key: TeamMemory::GLOBAL_TENANT_KEY, metadata: {})
          name_str = name.to_s
          if defined?(Agentkit::TeamRecord) && TeamMemory.ar_available?(Agentkit::TeamRecord)
            rec = Agentkit::TeamRecord.find_by(name: name_str, tenant_key: tenant_key) || Agentkit::TeamRecord.create!(
              name: name_str, description: description, owner_id: owner_id,
              account_id: account_id, tenant_key: tenant_key, metadata: metadata
            )
            from_record(rec)
          else
            team = new(id: registry.size + 1, name: name_str, description: description,
                       owner_id: owner_id, account_id: account_id, tenant_key: tenant_key, metadata: metadata)
            registry[registry_key(name_str, tenant_key)] = team
            team
          end
        end

        def find_by_name(name, tenant_key: TeamMemory::GLOBAL_TENANT_KEY, account_id: nil)
          name_str = name.to_s
          if defined?(Agentkit::TeamRecord) && TeamMemory.ar_available?(Agentkit::TeamRecord)
            rec = Agentkit::TeamRecord.find_by(name: name_str, tenant_key: tenant_key)
            rec ? from_record(rec) : nil
          else
            registry[registry_key(name_str, tenant_key)]
          end
        end

        def find_by_id(id, tenant_key: TeamMemory::GLOBAL_TENANT_KEY, account_id: nil)
          if defined?(Agentkit::TeamRecord) && TeamMemory.ar_available?(Agentkit::TeamRecord)
            scope = Agentkit::TeamRecord.where(id: id, tenant_key: tenant_key)
            scope = scope.where(account_id: account_id) if account_id
            rec = scope.first
            rec ? from_record(rec) : nil
          else
            registry.values.find do |team|
              team.id.to_s == id.to_s && team.tenant_key.to_s == tenant_key.to_s &&
                (account_id.nil? || team.account_id.to_s == account_id.to_s)
            end
          end
        end

        def find_or_create(name, **kwargs)
          tenant_key = kwargs[:tenant_key] || TeamMemory::GLOBAL_TENANT_KEY
          account_id = kwargs[:account_id]
          find_by_name(name, tenant_key: tenant_key, account_id: account_id) || create(name: name, **kwargs)
        end

        def reset!
          @registry = {}
        end

        private

        def registry_key(name, tenant_key)
          [tenant_key.to_s, name.to_s]
        end

        def from_record(rec)
          new(
            id: rec.id, name: rec.name, description: rec.description,
            owner_id: rec.owner_id, account_id: rec.account_id,
            tenant_key: rec.tenant_key, metadata: rec.metadata
          )
        end
      end

      def initialize(id: nil, name:, description: nil, owner_id: nil, account_id: nil,
                     tenant_key: TeamMemory::GLOBAL_TENANT_KEY, metadata: {})
        @id          = id
        @name        = name.to_s
        @description = description
        @owner_id    = owner_id
        @account_id  = account_id
        @tenant_key  = tenant_key
        @metadata    = metadata || {}
      end

      def assets
        AssetStore.list_for_team(id || name, tenant_key: tenant_key, account_id: account_id)
      end

      def equip(agent)
        TeamMemory.equip(agent: agent, team: name)
      end

      def to_h
        {
          id: id, name: name, description: description,
          owner_id: owner_id, account_id: account_id, tenant_key: tenant_key, metadata: metadata
        }
      end
    end
  end
end
