# frozen_string_literal: true

module Agentkit
  module TeamMemory
    # Wiki asset manager for team documentation, knowledge pages, and inter-page link graphs.
    class Wiki
      class Page
        attr_reader :id, :asset_id, :title, :content, :links, :status

        def initialize(id: nil, asset_id: nil, title:, content:, links: [], status: "ready")
          @id       = id
          @asset_id = asset_id
          @title    = title.to_s
          @content  = content.to_s
          @links    = Array(links).map(&:to_s)
          @status   = status.to_s
        end

        def to_h
          {
            "id"       => id,
            "asset_id" => asset_id,
            "title"    => title,
            "content"  => content,
            "links"    => links,
            "status"   => status
          }
        end
      end

      class << self
        def pages_store
          @pages_store ||= {}
        end

        def create_wiki(name:, team_id: nil, visibility: "team")
          AssetStore.create(
            asset_type: "wiki",
            name: name,
            team_id: team_id,
            visibility: visibility,
            content: { "page_count" => 0 }
          )
        end

        def add_page(asset_or_name, title:, content:, links: nil)
          asset = resolve_asset(asset_or_name)
          extracted_links = links || extract_wikilinks(content)

          if defined?(Agentkit::WikiPageRecord) && TeamMemory.ar_available?(Agentkit::WikiPageRecord) && asset.id
            rec = Agentkit::WikiPageRecord.create!(
              asset_id: asset.id,
              tenant_key: asset.tenant_key,
              account_id: asset.account_id,
              title: title,
              content: content,
              links: extracted_links
            )
            Page.new(id: rec.id, asset_id: rec.asset_id, title: rec.title, content: rec.content, links: rec.links)
          else
            page_id = pages_store.size + 1
            page = Page.new(
              id: page_id,
              asset_id: asset.id || asset.name,
              title: title,
              content: content,
              links: extracted_links
            )
            pages_store[page_id] = page
            page
          end
        end

        def search_pages(asset_or_name, query, limit: 5)
          asset = resolve_asset(asset_or_name)
          query_terms = query.to_s.downcase.scan(/[a-z0-9]{3,}/)
          return [] if query_terms.empty? || asset.nil?

          all_p = list_pages(asset)
          scored = all_p.filter_map do |page|
            text = "#{page.title} #{page.content}".downcase
            hits = query_terms.count { |t| text.include?(t) }
            [page, hits.to_f / query_terms.size] if hits.positive?
          end

          scored.sort_by { |(_, score)| -score }.first(limit).map(&:first)
        end

        # Materialize a deterministic, tenant-scoped Wiki graph. Unresolved
        # links remain diagnostics; they never become trusted placeholder nodes.
        def build_snapshot(asset_or_name, status: "validated")
          asset = resolve_asset(asset_or_name)
          pages = list_pages(asset).sort_by { |page| [normalize_title(page.title), page.id.to_s] }
          visibility = Graph.visibility_digest(asset)
          diagnostics = { "unresolved_links" => [], "duplicate_titles" => [], "cycles" => [] }
          by_title = {}

          pages.each do |page|
            key = normalize_title(page.title)
            if by_title.key?(key)
              diagnostics["duplicate_titles"] << { "title" => page.title, "page_id" => page.id.to_s }
            else
              by_title[key] = page
            end
          end

          nodes = pages.map do |page|
            ref = page.id || normalize_title(page.title)
            Graph::Node.new(
              node_id: Graph.node_id(asset: asset, type: :page, external_ref: ref),
              tenant_key: asset.tenant_key, asset_id: asset.id, node_type: :page,
              external_ref: ref, label: page.title,
              lifecycle_status: page.status == "ready" ? "active" : page.status,
              visibility_digest: visibility, content_digest: Graph.digest_for(page.content),
              metadata: { normalized_title: normalize_title(page.title), aliases: aliases_for(page) }
            )
          end
          node_by_page = pages.zip(nodes).to_h
          edges = []
          pages.each do |page|
            Array(page.links).map { |link| link.to_s.split("|", 2).first }.uniq { |link| normalize_title(link) }.each do |link|
              target = by_title[normalize_title(link)]
              unless target
                diagnostics["unresolved_links"] << { "from_page_id" => page.id.to_s, "target_digest" => Graph.digest_for(normalize_title(link)) }
                next
              end
              from = node_by_page.fetch(page).node_id
              to = node_by_page.fetch(target).node_id
              source = Graph.digest_for(page_id: page.id, target: normalize_title(link), content: page.content)
              edges << Graph::Edge.new(
                edge_id: Graph.edge_id(from: from, to: to, type: :wikilink, source_digest: source),
                from_node_id: from, to_node_id: to, edge_type: :wikilink,
                source_digest: source, metadata: { provenance: "wiki_ast", trust: "explicit" }
              )
            end
          end
          diagnostics["cycles"] = cycle_digests(nodes, edges)
          Graph.build(asset: asset, nodes: nodes, edges: edges, status: status,
                      diagnostics: diagnostics, metadata: { builder: "wiki", builder_version: 1 })
        end

        def list_pages(asset_or_name)
          asset = resolve_asset(asset_or_name)
          return [] if asset.nil?

          if defined?(Agentkit::WikiPageRecord) && TeamMemory.ar_available?(Agentkit::WikiPageRecord) && asset.id
            Agentkit::WikiPageRecord.where(asset_id: asset.id).map do |r|
              Page.new(id: r.id, asset_id: r.asset_id, title: r.title, content: r.content, links: r.links)
            end
          else
            key = asset.id || asset.name
            pages_store.values.select { |p| p.asset_id == key }
          end
        end

        def reset!
          @pages_store = {}
        end

        private

        def resolve_asset(asset_or_name)
          return asset_or_name if asset_or_name.is_a?(Asset)

          AssetStore.find_by_name(asset_or_name, asset_type: "wiki") ||
            create_wiki(name: asset_or_name)
        end

        def extract_wikilinks(text)
          text.to_s.scan(/\[\[(.*?)\]\]/).flatten.map(&:strip).uniq
        end

        def normalize_title(value)
          value.to_s.unicode_normalize(:nfkc).strip.gsub(/\s+/, " ").downcase
        end

        def aliases_for(page)
          ([page.title] + Array(page.links).filter_map do |link|
            parts = link.to_s.split("|", 2)
            parts[1] if parts.size == 2
          end).map { |value| normalize_title(value) }.uniq
        end

        def cycle_digests(nodes, edges)
          adjacency = Hash.new { |hash, key| hash[key] = [] }
          edges.each { |edge| adjacency[edge.from_node_id] << edge.to_node_id }
          visiting = {}
          visited = {}
          cycles = []
          visit = lambda do |id, path|
            return if visited[id]
            if visiting[id]
              start = path.index(id) || 0
              cycles << Graph.digest_for(path[start..] + [id])
              return
            end
            visiting[id] = true
            adjacency[id].each { |target| visit.call(target, path + [id]) }
            visiting.delete(id)
            visited[id] = true
          end
          nodes.each { |node| visit.call(node.node_id, []) }
          cycles.uniq.sort
        end
      end
    end
  end
end
