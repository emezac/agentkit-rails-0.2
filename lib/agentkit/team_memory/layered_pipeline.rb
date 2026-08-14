# frozen_string_literal: true

module Agentkit
  module TeamMemory
    # Pipeline for TencentDB 4-layer memory progression:
    # L0 (Raw interaction) -> L1 (Atoms) -> L2 (Scenes) -> L3 (Persona / Skill Assets)
    class LayeredPipeline
      LAYERS = {
        l0: 0, # Raw interaction logs
        l1: 1, # Extracted memory atoms (facts, preferences, decisions)
        l2: 2, # Clustered scenarios / scenes
        l3: 3  # High-level persona profiles / executable skills
      }.freeze

      class << self
        # Process raw L0 inputs into L1 memory atoms
        def process_l0_to_l1(raw_content, source_agent: nil, tags: [])
          atoms = []
          lines = Array(raw_content).flat_map { |c| c.to_s.lines }

          lines.each do |line|
            cleaned = line.strip
            next if cleaned.empty? || cleaned.length < 5

            # Categorize atom type
            type = if cleaned =~ /(prefer|like|want|always|never)/i
                     "preference"
                   elsif cleaned =~ /(decided|agreed|chose|selected)/i
                     "decision"
                   elsif cleaned =~ /(rule|must|should|require)/i
                     "rule"
                   else
                     "observation"
                   end

            atom = Memory.store(
              cleaned,
              source_agent: source_agent,
              tags: tags + ["layer:l1", type],
              type: type,
              ontological_type: "real",
              metadata: { "memory_layer" => LAYERS[:l1] }
            )
            atoms << atom
          end

          atoms
        end

        # Aggregate L1 atoms into L2 scenes
        def process_l1_to_l2(atoms, scene_name: nil, team_id: nil)
          scene_name ||= "scene_#{Time.now.to_i}"
          atom_contents = Array(atoms).map { |a| a.respond_to?(:content) ? a.content : a.to_s }

          # Store scene asset in AssetStore
          asset = AssetStore.create(
            asset_type: "chat_memory",
            name: scene_name,
            team_id: team_id,
            visibility: "team",
            content: {
              "layer"       => LAYERS[:l2],
              "scene_name"  => scene_name,
              "atom_count"  => atom_contents.size,
              "summary"     => atom_contents.join("\n"),
              "created_at"  => Time.now.iso8601
            }
          )

          asset
        end

        # Consolidate L2 scenes into L3 persona/skills
        def process_l2_to_l3(scenes, persona_name: nil, team_id: nil)
          persona_name ||= "persona_#{Time.now.to_i}"
          summaries = Array(scenes).map do |s|
            s.is_a?(Asset) ? s.content["summary"] : s.to_s
          end

          asset = AssetStore.create(
            asset_type: "skill",
            name: persona_name,
            team_id: team_id,
            visibility: "team",
            content: {
              "layer"         => LAYERS[:l3],
              "persona_name"  => persona_name,
              "profile"       => summaries.join("\n\n"),
              "consolidated" => true,
              "created_at"   => Time.now.iso8601
            }
          )

          asset
        end
      end
    end
  end
end
