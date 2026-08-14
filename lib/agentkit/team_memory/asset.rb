# frozen_string_literal: true

module Agentkit
  module TeamMemory
    # Value object representing a governed team memory asset.
    class Asset
      TYPES        = %w[chat_memory skill wiki code_graph].freeze
      VISIBILITIES = %w[private team restricted agent public].freeze

      attr_reader :id, :team_id, :asset_type, :name, :visibility, :owner_id,
                  :version, :status, :usage_count, :content, :bindings, :created_at

      def initialize(id: nil, team_id: nil, asset_type:, name:, visibility: "team",
                     owner_id: nil, version: "1.0.0", status: "ready", usage_count: 0,
                     content: {}, bindings: [], created_at: nil)
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
          "created_at"  => created_at
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
          if defined?(Agentkit::MemoryAssetRecord) && TeamMemory.ar_available?(Agentkit::MemoryAssetRecord)
            rec = Agentkit::MemoryAssetRecord.create!(kwargs)
            from_record(rec)
          else
            store.create(**kwargs)
          end
        end

        def find(id)
          if defined?(Agentkit::MemoryAssetRecord) && TeamMemory.ar_available?(Agentkit::MemoryAssetRecord)
            rec = Agentkit::MemoryAssetRecord.find_by(id: id)
            rec ? from_record(rec) : nil
          else
            store.find(id)
          end
        end

        def find_by_name(name, asset_type: nil)
          name_str = name.to_s
          if defined?(Agentkit::MemoryAssetRecord) && TeamMemory.ar_available?(Agentkit::MemoryAssetRecord)
            scope = Agentkit::MemoryAssetRecord.where(name: name_str)
            scope = scope.where(asset_type: asset_type.to_s) if asset_type
            rec = scope.first
            rec ? from_record(rec) : nil
          else
            store.find_by_name(name_str, asset_type: asset_type)
          end
        end

        def list_for_team(team_id, asset_type: nil)
          if defined?(Agentkit::MemoryAssetRecord) && TeamMemory.ar_available?(Agentkit::MemoryAssetRecord)
            scope = Agentkit::MemoryAssetRecord.where(team_id: team_id)
            scope = scope.where(asset_type: asset_type.to_s) if asset_type
            scope.map { |r| from_record(r) }
          else
            store.list_for_team(team_id, asset_type: asset_type)
          end
        end

        def all
          if defined?(Agentkit::MemoryAssetRecord) && TeamMemory.ar_available?(Agentkit::MemoryAssetRecord)
            Agentkit::MemoryAssetRecord.all.map { |r| from_record(r) }
          else
            store.all
          end
        end

        def reset!
          @store = InMemoryAssetStore.new
        end

        private

        def from_record(rec)
          Asset.new(
            id: rec.id, team_id: rec.team_id, asset_type: rec.asset_type,
            name: rec.name, visibility: rec.visibility, owner_id: rec.owner_id,
            version: rec.version, status: rec.status, usage_count: rec.usage_count,
            content: rec.content, bindings: rec.bindings, created_at: rec.created_at
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
                 version: "1.0.0", status: "ready", usage_count: 0, content: {}, bindings: [])
        @mutex.synchronize do
          id = (@seq += 1)
          asset = Asset.new(
            id: id, team_id: team_id, asset_type: asset_type, name: name,
            visibility: visibility, owner_id: owner_id, version: version,
            status: status, usage_count: usage_count, content: content,
            bindings: bindings, created_at: Time.now
          )
          @assets[id] = asset
          asset
        end
      end

      def find(id)
        @mutex.synchronize { @assets[id.to_i] }
      end

      def find_by_name(name, asset_type: nil)
        name_str = name.to_s
        type_str = asset_type&.to_s
        @mutex.synchronize do
          @assets.values.find do |a|
            a.name == name_str && (type_str.nil? || a.asset_type == type_str)
          end
        end
      end

      def list_for_team(team_id, asset_type: nil)
        team_str = team_id.to_s
        type_str = asset_type&.to_s
        @mutex.synchronize do
          @assets.values.select do |a|
            (a.team_id.to_s == team_str || a.team_id.nil?) &&
              (type_str.nil? || a.asset_type == type_str)
          end
        end
      end

      def all
        @mutex.synchronize { @assets.values.dup }
      end
    end
  end
end
