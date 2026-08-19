# frozen_string_literal: true

module Agentkit
  module TeamMemory
    # Value object representing a governed team memory asset.
    class Asset
      TYPES        = %w[chat_memory skill wiki code_graph].freeze
      VISIBILITIES = %w[private team restricted agent public].freeze

      attr_reader :id, :team_id, :asset_type, :name, :visibility, :owner_id,
                  :version, :status, :usage_count, :content, :bindings, :created_at,
                  :tenant_key, :account_id

      def initialize(id: nil, team_id: nil, asset_type:, name:, visibility: "team",
                     owner_id: nil, version: "1.0.0", status: "ready", usage_count: 0,
                     content: {}, bindings: [], created_at: nil,
                     tenant_key: TeamMemory::GLOBAL_TENANT_KEY, account_id: nil)
        unless TYPES.include?(asset_type.to_s)
          raise ConfigurationError, "Unknown TeamMemory asset type: #{asset_type}"
        end
        unless VISIBILITIES.include?(visibility.to_s)
          raise ConfigurationError, "Unknown TeamMemory visibility: #{visibility}"
        end
        raise ConfigurationError, "TeamMemory asset name cannot be blank" if name.to_s.strip.empty?

        @id          = id
        @team_id     = team_id
        @asset_type  = asset_type.to_s
        @name        = name.to_s
        @visibility  = visibility.to_s
        @owner_id    = owner_id
        @version     = version.to_s
        @status      = status.to_s
        @usage_count = usage_count.to_i
        @content     = content || {}
        @bindings    = Array(bindings).map(&:to_s)
        @created_at  = created_at || Time.now
        @tenant_key  = tenant_key
        @account_id  = account_id
      end

      def to_h
        {
          "id"          => id,
          "team_id"     => team_id,
          "asset_type"  => asset_type,
          "name"        => name,
          "visibility"  => visibility,
          "owner_id"    => owner_id,
          "version"     => version,
          "status"      => status,
          "usage_count" => usage_count,
          "content"     => content,
          "bindings"    => bindings,
          "created_at"  => created_at,
          "tenant_key"  => tenant_key,
          "account_id"  => account_id
        }
      end
    end

    # Storage adapter for Memory Assets (AR or InMemory).
    module AssetStore
      class << self
        def store
          @store ||= InMemoryAssetStore.new
        end

        def create(**kwargs)
          scope = TeamMemory.resolve_tenant_scope(
            tenant_key: kwargs.delete(:tenant_key), account_id: kwargs.delete(:account_id)
          )
          kwargs = kwargs.merge(scope)
          if kwargs[:team_id] && !Team.find_by_id(kwargs[:team_id], **scope)
            raise ConfigurationError, "Team #{kwargs[:team_id]} does not belong to tenant #{scope[:tenant_key]}"
          end
          if defined?(Agentkit::MemoryAssetRecord) && TeamMemory.ar_available?(Agentkit::MemoryAssetRecord)
            rec = Agentkit::MemoryAssetRecord.create!(kwargs)
            from_record(rec)
          else
            store.create(**kwargs)
          end
        end

        def find(id, tenant_key: nil, account_id: nil)
          scope = TeamMemory.resolve_tenant_scope(tenant_key: tenant_key, account_id: account_id)
          if defined?(Agentkit::MemoryAssetRecord) && TeamMemory.ar_available?(Agentkit::MemoryAssetRecord)
            rec = tenant_relation(**scope).find_by(id: id)
            rec ? from_record(rec) : nil
          else
            store.find(id, **scope)
          end
        end

        def find_by_name(name, asset_type: nil, tenant_key: nil, account_id: nil)
          scope_args = TeamMemory.resolve_tenant_scope(tenant_key: tenant_key, account_id: account_id)
          name_str = name.to_s
          if defined?(Agentkit::MemoryAssetRecord) && TeamMemory.ar_available?(Agentkit::MemoryAssetRecord)
            scope = tenant_relation(**scope_args).where(name: name_str)
            scope = scope.where(asset_type: asset_type.to_s) if asset_type
            rec = scope.first
            rec ? from_record(rec) : nil
          else
            store.find_by_name(name_str, asset_type: asset_type, **scope_args)
          end
        end

        def list_for_team(team_id, asset_type: nil, tenant_key: nil, account_id: nil)
          scope_args = TeamMemory.resolve_tenant_scope(tenant_key: tenant_key, account_id: account_id)
          if defined?(Agentkit::MemoryAssetRecord) && TeamMemory.ar_available?(Agentkit::MemoryAssetRecord)
            scope = tenant_relation(**scope_args).where(team_id: team_id)
            scope = scope.where(asset_type: asset_type.to_s) if asset_type
            scope.map { |r| from_record(r) }
          else
            store.list_for_team(team_id, asset_type: asset_type, **scope_args)
          end
        end

        def all(tenant_key: nil, account_id: nil)
          scope_args = TeamMemory.resolve_tenant_scope(tenant_key: tenant_key, account_id: account_id)
          if defined?(Agentkit::MemoryAssetRecord) && TeamMemory.ar_available?(Agentkit::MemoryAssetRecord)
            tenant_relation(**scope_args).map { |r| from_record(r) }
          else
            store.all(**scope_args)
          end
        end

        def reset!
          @store = InMemoryAssetStore.new
        end

        private

        def tenant_relation(tenant_key:, account_id: nil)
          relation = Agentkit::MemoryAssetRecord.where(tenant_key: tenant_key)
          relation = relation.where(account_id: account_id) if account_id
          relation
        end

        def from_record(rec)
          Asset.new(
            id: rec.id, team_id: rec.team_id, asset_type: rec.asset_type,
            name: rec.name, visibility: rec.visibility, owner_id: rec.owner_id,
            version: rec.version, status: rec.status, usage_count: rec.usage_count,
            content: rec.content, bindings: rec.bindings, created_at: rec.created_at,
            tenant_key: rec.tenant_key, account_id: rec.account_id
          )
        end
      end
    end

    class InMemoryAssetStore
      def initialize
        @assets = {}
        @seq    = 0
        @mutex  = Mutex.new
      end

      def create(asset_type:, name:, team_id: nil, visibility: "team", owner_id: nil,
                 version: "1.0.0", status: "ready", usage_count: 0, content: {}, bindings: [],
                 tenant_key: TeamMemory::GLOBAL_TENANT_KEY, account_id: nil)
        @mutex.synchronize do
          id = (@seq += 1)
          asset = Asset.new(
            id: id, team_id: team_id, asset_type: asset_type, name: name,
            visibility: visibility, owner_id: owner_id, version: version,
            status: status, usage_count: usage_count, content: content,
            bindings: bindings, created_at: Time.now,
            tenant_key: tenant_key, account_id: account_id
          )
          @assets[id] = asset
          asset
        end
      end

      def find(id, tenant_key:, account_id: nil)
        @mutex.synchronize do
          asset = @assets[id.to_i]
          asset if asset&.tenant_key.to_s == tenant_key.to_s
        end
      end

      def find_by_name(name, asset_type: nil, tenant_key:, account_id: nil)
        name_str = name.to_s
        type_str = asset_type&.to_s
        @mutex.synchronize do
          @assets.values.find do |a|
            a.tenant_key.to_s == tenant_key.to_s && a.name == name_str &&
              (type_str.nil? || a.asset_type == type_str)
          end
        end
      end

      def list_for_team(team_id, asset_type: nil, tenant_key:, account_id: nil)
        team_str = team_id.to_s
        type_str = asset_type&.to_s
        @mutex.synchronize do
          @assets.values.select do |a|
            a.tenant_key.to_s == tenant_key.to_s &&
              (a.team_id.to_s == team_str || a.team_id.nil?) &&
              (type_str.nil? || a.asset_type == type_str)
          end
        end
      end

      def all(tenant_key:, account_id: nil)
        @mutex.synchronize { @assets.values.select { |asset| asset.tenant_key.to_s == tenant_key.to_s } }
      end
    end
  end
end
