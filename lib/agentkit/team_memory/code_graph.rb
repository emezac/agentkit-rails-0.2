# frozen_string_literal: true

require "ripper"

module Agentkit
  module TeamMemory
    # CodeGraph asset manager for indexing codebases, symbols, call graphs, and impact analysis.
    class CodeGraph
      class SymbolEntry
        attr_reader :id, :asset_id, :name, :qualified_name, :symbol_type, :file_path,
                    :line_number, :callers, :callees, :file_digest, :provenance, :confidence

        def initialize(id: nil, asset_id: nil, name:, symbol_type:, file_path:,
                       line_number: nil, callers: [], callees: [], qualified_name: nil,
                       file_digest: nil, provenance: {}, confidence: 1.0)
          @id          = id
          @asset_id    = asset_id
          @name        = name.to_s
          @qualified_name = (qualified_name || name).to_s
          @symbol_type = symbol_type.to_s
          @file_path   = file_path.to_s
          @line_number = line_number
          @callers     = Array(callers).map(&:to_s)
          @callees     = Array(callees).map(&:to_s)
          @file_digest = file_digest
          @provenance = provenance || {}
          @confidence = confidence.to_f
        end

        def to_h
          {
            "id"          => id,
            "asset_id"    => asset_id,
            "name"        => name,
            "qualified_name" => qualified_name,
            "symbol_type" => symbol_type,
            "file_path"   => file_path,
            "line_number" => line_number,
            "callers"     => callers,
            "callees"     => callees,
            "file_digest" => file_digest,
            "provenance" => provenance,
            "confidence" => confidence
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
        def index_files(asset_or_name, file_paths, allowed_roots: nil)
          asset = resolve_asset(asset_or_name)
          entries = []

          Array(file_paths).each do |path|
            canonical = safe_path!(path, allowed_roots: allowed_roots)
            source = File.read(canonical)
            digest = Graph.digest_for(source)
            existing = all_syms(asset).select { |entry| entry.file_path == canonical }
            if existing.any? && existing.all? { |entry| entry.file_digest == digest }
              entries.concat(existing)
              next
            end
            delete_symbols_for_file(asset, canonical) if existing.any?
            extracted = parse_ruby_symbols(source, file_path: canonical)

            extracted.each do |sym|
              entry = add_symbol(
                asset,
                name: sym[:name],
                symbol_type: sym[:symbol_type],
                file_path: canonical,
                line_number: sym[:line_number],
                callers: sym[:callers],
                callees: sym[:callees], qualified_name: sym[:qualified_name],
                file_digest: digest,
                provenance: { "parser" => "ripper_ast", "ruby" => RUBY_VERSION,
                              "superclass" => sym[:superclass], "references" => sym[:references] }.compact,
                confidence: sym[:confidence] || 1.0
              )
              entries << entry
            end
          end

          entries
        end

        def add_symbol(asset_or_name, name:, symbol_type:, file_path:, line_number: nil, callers: [], callees: [],
                       qualified_name: nil, file_digest: nil, provenance: {}, confidence: 1.0)
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
              callees: callees,
              qualified_name: qualified_name || name, file_digest: file_digest,
              provenance: provenance, confidence: confidence
            )
            SymbolEntry.new(
              id: rec.id, asset_id: rec.asset_id, name: rec.name,
              symbol_type: rec.symbol_type, file_path: rec.file_path,
              line_number: rec.line_number, callers: rec.callers, callees: rec.callees,
              qualified_name: rec.respond_to?(:qualified_name) ? rec.qualified_name : rec.name,
              file_digest: rec.respond_to?(:file_digest) ? rec.file_digest : nil,
              provenance: rec.respond_to?(:provenance) ? rec.provenance : {},
              confidence: rec.respond_to?(:confidence) ? rec.confidence : 1.0
            )
          else
            sym_id = symbols_store.size + 1
            entry = SymbolEntry.new(
              id: sym_id, asset_id: asset.id || asset.name, name: name,
              symbol_type: symbol_type, file_path: file_path,
              line_number: line_number, callers: callers, callees: callees,
              qualified_name: qualified_name || name, file_digest: file_digest,
              provenance: provenance, confidence: confidence
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

        def build_snapshot(asset_or_name, status: "validated")
          asset = resolve_asset(asset_or_name)
          symbols = all_syms(asset)
          visibility = Graph.visibility_digest(asset)
          files = symbols.group_by(&:file_path)
          nodes = []
          node_by_key = {}
          files.each do |path, entries|
            ref = "file:#{path}"
            file_node = Graph::Node.new(
              node_id: Graph.node_id(asset: asset, type: :file, external_ref: ref),
              tenant_key: asset.tenant_key, asset_id: asset.id, node_type: :file,
              external_ref: ref, label: File.basename(path), visibility_digest: visibility,
              content_digest: entries.first.file_digest || Graph.digest_for(path),
              metadata: { path_digest: Graph.digest_for(path), provenance: "explicit_index_input" }
            )
            nodes << file_node
            node_by_key[[path, :file]] = file_node
            entries.each do |entry|
              ref = "#{entry.symbol_type}:#{entry.qualified_name}@#{path}"
              node = Graph::Node.new(
                node_id: Graph.node_id(asset: asset, type: entry.symbol_type, external_ref: ref),
                tenant_key: asset.tenant_key, asset_id: asset.id, node_type: entry.symbol_type,
                external_ref: ref, label: entry.qualified_name, visibility_digest: visibility,
                content_digest: Graph.digest_for(entry.to_h),
                metadata: { file_digest: entry.file_digest, line_number: entry.line_number,
                            provenance: entry.provenance, confidence: entry.confidence }
              )
              nodes << node
              node_by_key[[path, entry.qualified_name]] = node
            end
          end

          edges = []
          symbols.each do |entry|
            node = node_by_key[[entry.file_path, entry.qualified_name]]
            file = node_by_key[[entry.file_path, :file]]
            source = entry.file_digest || Graph.digest_for(entry.file_path)
            edges << graph_edge(file, node, :contains, source, confidence: 1.0, provenance: "ripper_ast")
            entry.callees.uniq.each do |callee|
              candidates = symbols.select { |candidate| candidate.name == callee || candidate.qualified_name == callee }
              candidates.each do |candidate|
                target = node_by_key[[candidate.file_path, candidate.qualified_name]]
                confidence = candidates.one? ? 0.9 : 0.5
                edges << graph_edge(node, target, :calls, source, confidence: confidence,
                                    provenance: candidates.one? ? "static_call" : "possible_dynamic_call")
              end
            end
            superclass = entry.provenance["superclass"] || entry.provenance[:superclass]
            if superclass
              symbols.select { |candidate| candidate.qualified_name == superclass || candidate.name == superclass }.each do |candidate|
                target = node_by_key[[candidate.file_path, candidate.qualified_name]]
                edges << graph_edge(node, target, :inherits, source, confidence: 1.0,
                                    provenance: "ripper_ast_superclass")
              end
            end
            Array(entry.provenance["references"] || entry.provenance[:references]).uniq.each do |reference|
              symbols.select { |candidate| candidate.qualified_name == reference || candidate.name == reference }.each do |candidate|
                target = node_by_key[[candidate.file_path, candidate.qualified_name]]
                next if target == node

                edges << graph_edge(node, target, :references, source, confidence: 0.8,
                                    provenance: "ripper_ast_constant")
              end
            end
          end
          Graph.build(asset: asset, nodes: nodes, edges: edges, status: status,
                      diagnostics: { "metaprogramming_complete" => false },
                      metadata: { builder: "code_graph", parser: "ripper_ast", builder_version: 1 })
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
                line_number: r.line_number, callers: r.callers, callees: r.callees,
                qualified_name: r.respond_to?(:qualified_name) ? r.qualified_name : r.name,
                file_digest: r.respond_to?(:file_digest) ? r.file_digest : nil,
                provenance: r.respond_to?(:provenance) ? r.provenance : {},
                confidence: r.respond_to?(:confidence) ? r.confidence : 1.0
              )
            end
          else
            key = asset.id || asset.name
            symbols_store.values.select { |s| s.asset_id == key }
          end
        end

        def delete_symbols_for_file(asset, path)
          if defined?(Agentkit::CodeSymbolRecord) && TeamMemory.ar_available?(Agentkit::CodeSymbolRecord) && asset.id
            Agentkit::CodeSymbolRecord.where(asset_id: asset.id, tenant_key: asset.tenant_key,
                                             file_path: path).delete_all
          else
            key = asset.id || asset.name
            symbols_store.delete_if { |_id, entry| entry.asset_id == key && entry.file_path == path }
          end
        end

        # Ruby AST parser. Regex is intentionally not an authoritative source.
        def parse_ruby_symbols(source, file_path:)
          sexp = Ripper.sexp(source)
          raise ConfigurationError, "Ruby parser rejected #{file_path}" unless sexp

          results = []
          walk_ast(sexp, namespace: [], results: results)
          results
        end

        def walk_ast(node, namespace:, results:, current_method: nil)
          return unless node.is_a?(Array)
          type = node[0]
          case type
          when :module
            name = constant_name(node[1])
            qualified = (namespace + [name]).reject(&:empty?).join("::")
            results << symbol_hash(name, qualified, "module", token_line(node[1]))
            walk_ast(node[2], namespace: namespace + [name], results: results)
            return
          when :class
            name = constant_name(node[1])
            qualified = name.include?("::") ? name : (namespace + [name]).join("::")
            entry = symbol_hash(name.split("::").last, qualified, "class", token_line(node[1]))
            entry[:superclass] = constant_name(node[2]) unless node[2].nil?
            results << entry
            walk_ast(node[3], namespace: qualified.split("::"), results: results, current_method: entry)
            return
          when :def
            token = node[1]
            name = token[1].to_s
            qualified = "#{namespace.join('::')}##{name}"
            entry = symbol_hash(name, qualified, "method", token.dig(2, 0))
            results << entry
            walk_ast(node[3], namespace: namespace, results: results, current_method: entry)
            return
          when :defs
            token = node[3]
            name = token[1].to_s
            qualified = "#{namespace.join('::')}.#{name}"
            entry = symbol_hash(name, qualified, "method", token.dig(2, 0))
            results << entry
            walk_ast(node[5], namespace: namespace, results: results, current_method: entry)
            return
          end

          if current_method && %i[const_ref const_path_ref top_const_ref].include?(type)
            reference = constant_name(node)
            current_method[:references] << reference unless reference.empty?
          end
          if current_method && %i[vcall fcall command call command_call].include?(type)
            token = type == :call ? node[3] : (type == :command_call ? node[3] : node[1])
            current_method[:callees] << token[1].to_s if token.is_a?(Array) && token[0].to_s.start_with?("@")
          end
          node.each { |child| walk_ast(child, namespace: namespace, results: results, current_method: current_method) if child.is_a?(Array) }
        end

        def symbol_hash(name, qualified, type, line)
          { name: name, qualified_name: qualified, symbol_type: type, line_number: line,
            callers: [], callees: [], references: [], confidence: 1.0 }
        end

        def constant_name(node)
          return "" unless node.is_a?(Array)
          return node[1].to_s if node[0] == :@const
          return node.filter_map { |child| constant_name(child) if child.is_a?(Array) }.reject(&:empty?).join("::") if
            %i[const_path_ref const_path_field top_const_ref].include?(node[0])

          node.filter_map { |child| constant_name(child) if child.is_a?(Array) }.reject(&:empty?).first.to_s
        end

        def token_line(node)
          return node.dig(2, 0) if node.is_a?(Array) && node[0].to_s.start_with?("@")

          node.is_a?(Array) && node.filter_map { |child| token_line(child) if child.is_a?(Array) }.first
        end

        def safe_path!(path, allowed_roots: nil)
          given = File.expand_path(path.to_s)
          raise ConfigurationError, "CodeGraph path does not exist" unless File.file?(given)
          raise ConfigurationError, "CodeGraph refuses symlinks" if File.symlink?(given)
          canonical = File.realpath(given)
          roots = Array(allowed_roots || Agentkit.config.team_memory.graph_allowed_roots).map { |root| File.realpath(root) }
          if roots.any? && roots.none? { |root| canonical == root || canonical.start_with?("#{root}#{File::SEPARATOR}") }
            raise ConfigurationError, "CodeGraph path is outside allowed roots"
          end
          if File.size(canonical) > Agentkit.config.team_memory.graph_max_file_bytes.to_i
            raise ConfigurationError, "CodeGraph file exceeds size limit"
          end
          canonical
        end

        def graph_edge(from, to, type, source, confidence:, provenance:)
          Graph::Edge.new(
            edge_id: Graph.edge_id(from: from.node_id, to: to.node_id, type: type, source_digest: source),
            from_node_id: from.node_id, to_node_id: to.node_id, edge_type: type,
            source_digest: source, confidence: confidence,
            metadata: { provenance: provenance, trust: "static" }
          )
        end
      end
    end
  end
end
