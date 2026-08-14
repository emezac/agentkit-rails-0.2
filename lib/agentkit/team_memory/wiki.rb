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
      end
    end
  end
end
