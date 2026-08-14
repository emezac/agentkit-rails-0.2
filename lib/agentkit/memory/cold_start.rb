# frozen_string_literal: true

require "json"
require "time"

module Agentkit
  module Memory
    # ColdStart utility for importing historical conversations and transcripts into AgentKit memory.
    class ColdStart
      class << self
        # Import conversation entries from a JSON file, JSONL file, or Array of objects.
        #
        # @param source [String, Array] File path to JSON/JSONL or Array of hashes
        # @param default_agent [String] Default source agent name
        # @param extract_layers [Boolean] Automatically process L0 -> L1 atoms
        # @return [Hash] Import stats ({ imported: count, atoms: count })
        def import(source, default_agent: "HistoricalImport", extract_layers: true)
          entries = parse_source(source)
          imported_records = []

          entries.each do |entry|
            content    = entry["content"] || entry[:content] || entry["text"] || entry[:text]
            next if content.nil? || content.to_s.strip.empty?

            timestamp  = parse_time(entry["timestamp"] || entry[:timestamp] || entry["created_at"] || entry[:created_at])
            agent_name = entry["agent"] || entry[:agent] || entry["source_agent"] || entry[:source_agent] || default_agent
            tags       = Array(entry["tags"] || entry[:tags]) + ["cold_start", "historical"]
            type       = entry["type"] || entry[:type] || "observation"

            record = Memory.store(
              content,
              source_agent: agent_name,
              tags: tags,
              type: type,
              ontological_type: "real",
              metadata: { "imported_at" => Time.now.iso8601, "original_timestamp" => timestamp.iso8601 }
            )
            imported_records << record
          end

          atoms_count = 0
          if extract_layers && defined?(TeamMemory::LayeredPipeline)
            raw_texts = imported_records.map(&:content)
            atoms = TeamMemory::LayeredPipeline.process_l0_to_l1(raw_texts, source_agent: default_agent, tags: ["cold_start"])
            atoms_count = atoms.size
          end

          { imported: imported_records.size, atoms: atoms_count }
        end

        private

        def parse_source(source)
          if source.is_a?(Array)
            source
          elsif source.is_a?(String) && File.exist?(source)
            raw = File.read(source)
            if source.end_with?(".jsonl")
              raw.lines.filter_map { |l| parse_json(l) }
            else
              parsed = parse_json(raw)
              parsed.is_a?(Array) ? parsed : [parsed]
            end
          else
            []
          end
        end

        def parse_json(str)
          JSON.parse(str)
        rescue JSON::ParserError
          nil
        end

        def parse_time(val)
          return Time.now if val.nil?

          Time.parse(val.to_s)
        rescue ArgumentError
          Time.now
        end
      end
    end
  end
end
