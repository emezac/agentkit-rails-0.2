# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"
require "time"

module Agentkit
  module TeamMemory
    # Normalized, immutable graph snapshots shared by Wiki, CodeGraph and RAG.
    module Graph
      SCHEMA_VERSION = 1
      ACTIVE_STATUSES = %w[validated active].freeze
      NODE_LIFECYCLES = %w[active validated].freeze
      MAX_WEIGHT = 1_000.0

      class Node
        attr_reader :node_id, :tenant_key, :asset_id, :node_type, :external_ref,
                    :lifecycle_status, :visibility_digest, :content_digest, :label, :metadata

        def initialize(node_id:, tenant_key:, asset_id:, node_type:, external_ref:,
                       lifecycle_status: "active", visibility_digest:, content_digest:,
                       label: nil, metadata: {})
          @node_id = node_id.to_s
          @tenant_key = tenant_key.to_s
          @asset_id = asset_id
          @node_type = node_type.to_s
          @external_ref = external_ref.to_s
          @lifecycle_status = lifecycle_status.to_s
          @visibility_digest = visibility_digest.to_s
          @content_digest = content_digest.to_s
          @label = label&.to_s
          @metadata = (metadata || {}).transform_keys(&:to_s).freeze
          freeze
        end

        def to_h
          { node_id: node_id, tenant_key: tenant_key, asset_id: asset_id, node_type: node_type,
            external_ref: external_ref, lifecycle_status: lifecycle_status,
            visibility_digest: visibility_digest, content_digest: content_digest,
            label: label, metadata: metadata }
        end
      end

      class Edge
        attr_reader :edge_id, :snapshot_id, :from_node_id, :to_node_id, :edge_type,
                    :direction, :weight, :source_digest, :confidence, :lifecycle_status, :metadata

        def initialize(edge_id:, snapshot_id: nil, from_node_id:, to_node_id:, edge_type:,
                       direction: "outbound", weight: 1.0, source_digest:, confidence: 1.0,
                       lifecycle_status: "active", metadata: {})
          numeric_weight = Float(weight)
          numeric_confidence = Float(confidence)
          unless numeric_weight.finite? && numeric_weight >= 0 && numeric_weight <= MAX_WEIGHT
            raise ConfigurationError, "graph edge weight must be finite and between 0 and #{MAX_WEIGHT}"
          end
          unless numeric_confidence.finite? && numeric_confidence.between?(0.0, 1.0)
            raise ConfigurationError, "graph edge confidence must be between 0 and 1"
          end

          @edge_id = edge_id.to_s
          @snapshot_id = snapshot_id&.to_s
          @from_node_id = from_node_id.to_s
          @to_node_id = to_node_id.to_s
          @edge_type = edge_type.to_s
          @direction = direction.to_s
          @weight = numeric_weight
          @source_digest = source_digest.to_s
          raise ConfigurationError, "graph edge source digest is required" if @source_digest.empty?
          @confidence = numeric_confidence
          @lifecycle_status = lifecycle_status.to_s
          @metadata = (metadata || {}).transform_keys(&:to_s).freeze
          freeze
        end

        def with_snapshot(value)
          self.class.new(**to_h.merge(snapshot_id: value))
        end

        def to_h
          { edge_id: edge_id, snapshot_id: snapshot_id, from_node_id: from_node_id,
            to_node_id: to_node_id, edge_type: edge_type, direction: direction,
            weight: weight, source_digest: source_digest, confidence: confidence,
            lifecycle_status: lifecycle_status, metadata: metadata }
        end
      end

      class Snapshot
        attr_reader :snapshot_id, :tenant_key, :account_id, :asset_id, :schema_version,
                    :generated_at, :digest, :status, :nodes, :edges, :diagnostics, :metadata

        def initialize(snapshot_id:, tenant_key:, asset_id:, nodes:, edges:, digest:,
                       account_id: nil, schema_version: SCHEMA_VERSION, generated_at: Time.now.utc,
                       status: "validated", diagnostics: {}, metadata: {})
          @snapshot_id = snapshot_id.to_s
          @tenant_key = tenant_key.to_s
          @account_id = account_id
          @asset_id = asset_id
          @schema_version = schema_version.to_i
          @generated_at = generated_at
          @digest = digest.to_s
          @status = status.to_s
          @nodes = Array(nodes).freeze
          @edges = Array(edges).map { |edge| edge.snapshot_id == @snapshot_id ? edge : edge.with_snapshot(@snapshot_id) }.freeze
          @diagnostics = (diagnostics || {}).freeze
          @metadata = (metadata || {}).freeze
          validate!
          freeze
        end

        def node_count = nodes.size
        def edge_count = edges.size
        def active? = ACTIVE_STATUSES.include?(status)

        def to_h
          { snapshot_id: snapshot_id, tenant_key: tenant_key, account_id: account_id,
            asset_id: asset_id, schema_version: schema_version, generated_at: generated_at,
            node_count: node_count, edge_count: edge_count, digest: digest, status: status,
            diagnostics: diagnostics, metadata: metadata,
            nodes: nodes.map(&:to_h), edges: edges.map(&:to_h) }
        end

        private

        def validate!
          raise ConfigurationError, "graph snapshot status must be validated or active" unless active?
          node_ids = nodes.map(&:node_id)
          raise ConfigurationError, "graph snapshot has duplicate node ids" unless node_ids.uniq.size == node_ids.size
          raise ConfigurationError, "graph snapshot mixes tenants" if nodes.any? { |node| node.tenant_key != tenant_key }
          raise ConfigurationError, "graph snapshot mixes assets" if nodes.any? { |node| node.asset_id.to_s != asset_id.to_s }
          unless edges.all? { |edge| node_ids.include?(edge.from_node_id) && node_ids.include?(edge.to_node_id) }
            raise ConfigurationError, "graph edge references a node outside its snapshot"
          end
          unsafe_llm = edges.any? do |edge|
            provenance = edge.metadata["provenance"].to_s.downcase
            provenance.include?("llm") && edge.metadata["validated"] != true
          end
          raise ConfigurationError, "unvalidated LLM graph edge cannot enter an active snapshot" if unsafe_llm
        end
      end

      class VisibleSnapshot
        attr_reader :snapshot, :nodes, :edges, :principal_digest

        def initialize(snapshot:, nodes:, edges:, principal_digest:)
          @snapshot = snapshot
          @nodes = nodes.freeze
          @edges = edges.freeze
          @principal_digest = principal_digest
          freeze
        end

        def snapshot_id = snapshot.snapshot_id
        def digest = snapshot.digest
        def tenant_key = snapshot.tenant_key
        def asset_id = snapshot.asset_id
        def node_count = nodes.size
        def edge_count = edges.size
      end

      class << self
        def store
          if active_record_available?
            ActiveRecordStore.new
          else
            @store ||= InMemoryStore.new
          end
        end

        def build(asset:, nodes:, edges:, status: "validated", diagnostics: {}, metadata: {})
          asset = resolve_asset(asset)
          raise ConfigurationError, "graph asset not found" unless asset

          canonical_nodes = Array(nodes).sort_by(&:node_id)
          canonical_edges = Array(edges).sort_by { |edge| [edge.from_node_id, edge.to_node_id, edge.edge_type, edge.edge_id] }
          digest = digest_for(nodes: canonical_nodes.map(&:to_h), edges: canonical_edges.map { |e| e.to_h.reject { |k, _| k == :snapshot_id } })
          if (existing = store.find_by_digest(asset_id: asset.id, tenant_key: asset.tenant_key, digest: digest))
            return existing
          end

          snapshot = Snapshot.new(
            snapshot_id: SecureRandom.uuid, tenant_key: asset.tenant_key, account_id: asset.account_id,
            asset_id: asset.id, nodes: canonical_nodes, edges: canonical_edges, digest: digest,
            status: status, diagnostics: diagnostics, metadata: metadata
          )
          store.save(snapshot)
          Telemetry.emit("graph.snapshot.built",
                         dims: { tenant: opaque(snapshot.tenant_key), asset_type: asset.asset_type,
                                 status: snapshot.status, schema_version: snapshot.schema_version },
                         measures: { nodes: snapshot.node_count, edges: snapshot.edge_count })
          snapshot
        end

        # Build a chunk graph from explicit source metadata. Relationships are
        # never inferred by an LLM; absent references simply produce no edge.
        def build_rag(asset:, chunks:, status: "validated")
          asset = resolve_asset(asset)
          raise ConfigurationError, "RAG graph asset not found" unless asset&.asset_type == "rag"

          visibility = visibility_digest(asset)
          normalized = Array(chunks).map { |chunk| chunk.to_h.transform_keys(&:to_s) }
          nodes = normalized.map do |chunk|
            ref = chunk["id"] || chunk["chunk_id"] || digest_for(chunk)
            Node.new(node_id: node_id(asset: asset, type: :chunk, external_ref: ref),
                     tenant_key: asset.tenant_key, asset_id: asset.id, node_type: :chunk,
                     external_ref: ref, label: chunk["title"] || chunk["chapter_title"],
                     lifecycle_status: chunk["status"] || "active",
                     visibility_digest: visibility,
                     content_digest: digest_for(chunk["text"] || chunk["content"] || ""),
                     metadata: { source_digest: digest_for(chunk["source"].to_s),
                                 hidden: chunk["hidden"] == true,
                                 allowed_principal_ids: Array(chunk["allowed_principal_ids"]) })
          end
          by_ref = nodes.to_h { |node| [node.external_ref, node] }
          edges = []
          normalized.zip(nodes).group_by { |(chunk, _node)| chunk["source"].to_s }.each_value do |pairs|
            pairs.each_cons(2) do |(_left_chunk, left), (_right_chunk, right)|
              source = digest_for([left.content_digest, right.content_digest])
              edges << Edge.new(edge_id: edge_id(from: left.node_id, to: right.node_id,
                                                  type: :same_source, source_digest: source),
                                from_node_id: left.node_id, to_node_id: right.node_id,
                                edge_type: :same_source, source_digest: source,
                                metadata: { provenance: "chunk_metadata", trust: "explicit" })
            end
          end
          normalized.zip(nodes).each do |chunk, node|
            Array(chunk["references"]).each do |reference|
              target = by_ref[reference.to_s]
              next unless target

              source = digest_for(chunk_id: node.external_ref, reference: target.external_ref)
              edges << Edge.new(edge_id: edge_id(from: node.node_id, to: target.node_id,
                                                  type: :references, source_digest: source),
                                from_node_id: node.node_id, to_node_id: target.node_id,
                                edge_type: :references, source_digest: source,
                                metadata: { provenance: "chunk_metadata", trust: "explicit" })
            end
          end
          build(asset: asset, nodes: nodes, edges: edges, status: status,
                metadata: { builder: "rag", builder_version: 1 })
        end

        def latest(asset, tenant_key: nil)
          asset = resolve_asset(asset, tenant_key: tenant_key)
          return nil unless asset

          store.latest(asset_id: asset.id, tenant_key: asset.tenant_key)
        end

        # Authorization is deliberately completed before any adjacency is built.
        def visible(snapshot, context: Context.resolve)
          raise ConfigurationError, "graph snapshot is not active" unless snapshot&.active?
          tenant = context.tenant_key || TeamMemory::GLOBAL_TENANT_KEY
          raise ConfigurationError, "graph snapshot belongs to another tenant" unless snapshot.tenant_key == tenant.to_s

          asset = AssetStore.find(snapshot.asset_id, tenant_key: tenant, account_id: id_of(context.account))
          return nil unless asset && ACL.accessible?(asset, **acl_context(context), tenant_key: tenant)

          principal = context.principal || context.user
          current_visibility = visibility_digest(asset)
          visible_nodes = snapshot.nodes.select do |node|
            NODE_LIFECYCLES.include?(node.lifecycle_status) &&
              node.visibility_digest == current_visibility && node_visible?(node, principal)
          end
          ids = visible_nodes.to_h { |node| [node.node_id, true] }
          candidate_edges = snapshot.edges.select do |edge|
            NODE_LIFECYCLES.include?(edge.lifecycle_status) && edge.confidence.positive? &&
              ids[edge.from_node_id] && ids[edge.to_node_id]
          end
          max_degree = [[Agentkit.config.team_memory.graph_max_degree.to_i, 1].max, 10_000].min
          degree = Hash.new(0)
          visible_edges = candidate_edges.sort_by(&:edge_id).select do |edge|
            next false if degree[edge.from_node_id] >= max_degree || degree[edge.to_node_id] >= max_degree

            degree[edge.from_node_id] += 1
            degree[edge.to_node_id] += 1
            true
          end
          VisibleSnapshot.new(snapshot: snapshot, nodes: visible_nodes, edges: visible_edges,
                              principal_digest: principal_digest(context, asset))
        end

        def digest_for(value)
          "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(value)))}"
        end

        def visibility_digest(asset)
          digest_for(tenant_key: asset.tenant_key, asset_id: asset.id, visibility: asset.visibility,
                     owner_id: asset.owner_id, team_id: asset.team_id, bindings: asset.bindings.sort)
        end

        def node_id(asset:, type:, external_ref:)
          "node:#{Digest::SHA256.hexdigest([asset.tenant_key, asset.id, type, external_ref].join("\0"))}"
        end

        def edge_id(from:, to:, type:, source_digest:)
          "edge:#{Digest::SHA256.hexdigest([from, to, type, source_digest].join("\0"))}"
        end

        def opaque(value)
          Digest::SHA256.hexdigest(value.to_s)[0, 20]
        end

        def alias_for(visible_snapshot, node_id)
          "g_#{Digest::SHA256.hexdigest([visible_snapshot.digest, visible_snapshot.principal_digest, node_id].join("\0"))[0, 20]}"
        end

        def reset!
          @store = InMemoryStore.new
        end

        private

        def active_record_available?
          defined?(Agentkit::GraphSnapshotRecord) && TeamMemory.ar_available?(Agentkit::GraphSnapshotRecord)
        end

        def resolve_asset(value, tenant_key: nil)
          return value if value.is_a?(Asset)

          AssetStore.find_by_name(value, tenant_key: tenant_key)
        end

        def node_visible?(node, principal)
          allowed = Array(node.metadata["allowed_principal_ids"])
          return false if node.metadata["hidden"] == true
          return true if allowed.empty?

          principal_id = principal.respond_to?(:id) ? principal.id : principal
          allowed.map(&:to_s).include?(principal_id.to_s)
        end

        def acl_context(context)
          metadata = context.metadata || {}
          { agent_name: metadata[:agent_name] || metadata["agent_name"],
            team_id: metadata[:team_id] || metadata["team_id"],
            owner_id: id_of(context.user) || metadata[:owner_id] || metadata["owner_id"] }
        end

        def principal_digest(context, asset)
          principal = context.principal || context.user
          id = principal.respond_to?(:id) ? principal.id : principal
          digest_for(tenant: context.tenant_key, principal: id, visibility: visibility_digest(asset))
        end

        def canonical(value)
          case value
          when Hash
            value.to_h.sort_by { |key, _| key.to_s }.to_h { |key, item| [key.to_s, canonical(item)] }
          when Array then value.map { |item| canonical(item) }
          when Time then value.utc.iso8601(6)
          else value
          end
        end

        def id_of(value) = value.respond_to?(:id) ? value.id : value
      end

      class InMemoryStore
        def initialize
          @snapshots = []
          @mutex = Mutex.new
        end

        def save(snapshot)
          @mutex.synchronize { @snapshots << snapshot }
          snapshot
        end

        def find_by_digest(asset_id:, tenant_key:, digest:)
          @mutex.synchronize do
            @snapshots.reverse.find { |s| s.asset_id.to_s == asset_id.to_s && s.tenant_key == tenant_key.to_s && s.digest == digest }
          end
        end

        def latest(asset_id:, tenant_key:)
          @mutex.synchronize do
            @snapshots.reverse.find { |s| s.asset_id.to_s == asset_id.to_s && s.tenant_key == tenant_key.to_s && s.active? }
          end
        end

        def all(tenant_key: nil)
          @mutex.synchronize { tenant_key ? @snapshots.select { |s| s.tenant_key == tenant_key.to_s } : @snapshots.dup }
        end
      end

      class ActiveRecordStore
        def save(snapshot)
          record = nil
          Agentkit::GraphSnapshotRecord.transaction do
            record = Agentkit::GraphSnapshotRecord.create!(
              snapshot_id: snapshot.snapshot_id, tenant_key: snapshot.tenant_key,
              account_id: snapshot.account_id, asset_id: snapshot.asset_id,
              schema_version: snapshot.schema_version, generated_at: snapshot.generated_at,
              node_count: snapshot.node_count, edge_count: snapshot.edge_count,
              digest: snapshot.digest, status: snapshot.status,
              diagnostics: snapshot.diagnostics, metadata: snapshot.metadata
            )
            now = Time.now
            Agentkit::GraphNodeRecord.insert_all(snapshot.nodes.map do |node|
              node.to_h.merge(snapshot_id: record.id, account_id: snapshot.account_id,
                              created_at: now, updated_at: now)
            end)
            Agentkit::GraphEdgeRecord.insert_all(snapshot.edges.map do |edge|
              edge.to_h.reject { |key, _| key == :snapshot_id }.merge(
                snapshot_id: record.id, tenant_key: snapshot.tenant_key,
                account_id: snapshot.account_id, created_at: now, updated_at: now
              )
            end)
          end
          snapshot
        rescue ActiveRecord::RecordNotUnique
          find_by_digest(asset_id: snapshot.asset_id, tenant_key: snapshot.tenant_key, digest: snapshot.digest)
        end

        def find_by_digest(asset_id:, tenant_key:, digest:)
          relation(asset_id, tenant_key).find_by(digest: digest)&.then { |record| hydrate(record) }
        end

        def latest(asset_id:, tenant_key:)
          record = relation(asset_id, tenant_key).where(status: ACTIVE_STATUSES).order(generated_at: :desc, id: :desc).first
          record && hydrate(record)
        end

        def all(tenant_key: nil)
          rel = Agentkit::GraphSnapshotRecord.all
          rel = rel.where(tenant_key: tenant_key) if tenant_key
          rel.order(:id).map { |record| hydrate(record) }
        end

        private

        def relation(asset_id, tenant_key)
          Agentkit::GraphSnapshotRecord.where(asset_id: asset_id, tenant_key: tenant_key)
        end

        def hydrate(record)
          nodes = record.graph_nodes.map do |node|
            Node.new(**node.attributes.symbolize_keys.slice(
              :node_id, :tenant_key, :asset_id, :node_type, :external_ref,
              :lifecycle_status, :visibility_digest, :content_digest, :label, :metadata
            ))
          end
          edges = record.graph_edges.map do |edge|
            Edge.new(**edge.attributes.symbolize_keys.slice(
              :edge_id, :from_node_id, :to_node_id, :edge_type, :direction, :weight,
              :source_digest, :confidence, :lifecycle_status, :metadata
            ).merge(snapshot_id: record.snapshot_id))
          end
          Snapshot.new(snapshot_id: record.snapshot_id, tenant_key: record.tenant_key,
                       account_id: record.account_id, asset_id: record.asset_id,
                       schema_version: record.schema_version, generated_at: record.generated_at,
                       nodes: nodes, edges: edges, digest: record.digest, status: record.status,
                       diagnostics: record.diagnostics, metadata: record.metadata)
        end
      end
    end
  end
end
