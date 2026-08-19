# frozen_string_literal: true

require "ripper"

module Agentkit
  module TeamMemory
    # CodeGraph asset manager for indexing codebases, symbols, call graphs, and impact analysis.
    class CodeGraph
      class SymbolEntry
        attr_reader :id, :asset_id, :name, :symbol_type, :file_path, :line_number, :callers, :callees

        def initialize(id: nil, asset_id: nil, name:, symbol_type:, file_path:,
                       line_number: nil, callers: [], callees: [])
          @id          = id
          @asset_id    = asset_id
          @name        = name.to_s
          @symbol_type = symbol_type.to_s
          @file_path   = file_path.to_s
          @line_number = line_number
          @callers     = Array(callers).map(&:to_s)
          @callees     = Array(callees).map(&:to_s)
        end

        def to_h
          {
            "id"          => id,
            "asset_id"    => asset_id,
            "name"        => name,
            "symbol_type" => symbol_type,
            "file_path"   => file_path,
            "line_number" => line_number,
            "callers"     => callers,
            "callees"     => callees
          }
        end
      end

      class << self
        def symbols_store
          @symbols_store ||= {}
        end

        def create_graph(name:, team_id: nil, visibility: "team")
          AssetStore.create(
            asset_type: "code_graph",
            name: name,
            team_id: team_id,
            visibility: visibility
          )
        end

        # Index a directory or list of source code files into a CodeGraph asset.
        def index_files(asset_or_name, file_paths)
          asset = resolve_asset(asset_or_name)
          entries = []

          Array(file_paths).each do |path|
            next unless File.exist?(path)

            source = File.read(path)
            extracted = parse_ruby_symbols(source, file_path: path)

            extracted.each do |sym|
              entry = add_symbol(
                asset,
                name: sym[:name],
                symbol_type: sym[:symbol_type],
                file_path: path,
                line_number: sym[:line_number],
                callers: sym[:callers],
                callees: sym[:callees]
              )
              entries << entry
            end
          end

          entries
        end

        def add_symbol(asset_or_name, name:, symbol_type:, file_path:, line_number: nil, callers: [], callees: [])
          asset = resolve_asset(asset_or_name)

          if defined?(Agentkit::CodeSymbolRecord) && TeamMemory.ar_available?(Agentkit::CodeSymbolRecord) && asset.id
            rec = Agentkit::CodeSymbolRecord.create!(
              asset_id: asset.id,
              tenant_key: asset.tenant_key,
              account_id: asset.account_id,
              name: name,
              symbol_type: symbol_type,
              file_path: file_path,
              line_number: line_number,
              callers: callers,
              callees: callees
            )
            SymbolEntry.new(
              id: rec.id, asset_id: rec.asset_id, name: rec.name,
              symbol_type: rec.symbol_type, file_path: rec.file_path,
              line_number: rec.line_number, callers: rec.callers, callees: rec.callees
            )
          else
            sym_id = symbols_store.size + 1
            entry = SymbolEntry.new(
              id: sym_id, asset_id: asset.id || asset.name, name: name,
              symbol_type: symbol_type, file_path: file_path,
              line_number: line_number, callers: callers, callees: callees
            )
            symbols_store[sym_id] = entry
            entry
          end
        end

        def find_symbol(asset_or_name, name)
          asset = resolve_asset(asset_or_name)
          return nil if asset.nil?

          name_str = name.to_s
          all_syms(asset).find { |s| s.name == name_str }
        end

        def impact_analysis(asset_or_name, symbol_name)
          asset = resolve_asset(asset_or_name)
          sym = find_symbol(asset, symbol_name)
          return [] if sym.nil?

          visited = Set.new
          queue = [sym.name]
          impacted = []

          until queue.empty?
            curr_name = queue.shift
            next if visited.include?(curr_name)

            visited.add(curr_name)
            target_sym = find_symbol(asset, curr_name)
            next if target_sym.nil?

            impacted << target_sym
            target_sym.callers.each do |caller_name|
              queue << caller_name unless visited.include?(caller_name)
            end
          end

          impacted
        end

        def all_symbols(asset_or_name)
          asset = resolve_asset(asset_or_name)
          return [] if asset.nil?

          all_syms(asset)
        end

        def reset!
          @symbols_store = {}
        end

        private

        def resolve_asset(asset_or_name)
          return asset_or_name if asset_or_name.is_a?(Asset)

          AssetStore.find_by_name(asset_or_name, asset_type: "code_graph") ||
            create_graph(name: asset_or_name)
        end

        def all_syms(asset)
          if defined?(Agentkit::CodeSymbolRecord) && TeamMemory.ar_available?(Agentkit::CodeSymbolRecord) && asset.id
            Agentkit::CodeSymbolRecord.where(asset_id: asset.id).map do |r|
              SymbolEntry.new(
                id: r.id, asset_id: r.asset_id, name: r.name,
                symbol_type: r.symbol_type, file_path: r.file_path,
                line_number: r.line_number, callers: r.callers, callees: r.callees
              )
            end
          else
            key = asset.id || asset.name
            symbols_store.values.select { |s| s.asset_id == key }
          end
        end

        # Fast Ruby symbol parser using Ripper or regex scanning
        def parse_ruby_symbols(source, file_path:)
          results = []
          lines = source.lines

          lines.each_with_index do |line, idx|
            line_no = idx + 1
            if line =~ /^\s*class\s+([A-Z][A-Za-z0-9_:]*)/
              results << { name: Regexp.last_match(1), symbol_type: "class", line_number: line_no, callers: [], callees: [] }
            elsif line =~ /^\s*module\s+([A-Z][A-Za-z0-9_:]*)/
              results << { name: Regexp.last_match(1), symbol_type: "module", line_number: line_no, callers: [], callees: [] }
            elsif line =~ /^\s*def\s+([a-z0-9_?!]+)/
              results << { name: Regexp.last_match(1), symbol_type: "method", line_number: line_no, callers: [], callees: [] }
            end
          end

          results
        end
      end
    end
  end
end
