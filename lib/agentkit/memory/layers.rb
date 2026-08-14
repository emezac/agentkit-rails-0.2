# frozen_string_literal: true

module Agentkit
  module Memory
    # TencentDB Layered Memory structure helper:
    # L0: Raw interaction logs / conversation turns
    # L1: Extracted memory atoms (facts, rules, preferences, decisions)
    # L2: Clustered scenarios / contextual scenes
    # L3: High-level consolidated persona profile & executable skills
    module Layers
      L0_RAW        = 0
      L1_ATOMS      = 1
      L2_SCENES     = 2
      L3_PERSONA    = 3

      LAYER_NAMES = {
        0 => "L0: Raw Interaction",
        1 => "L1: Memory Atom",
        2 => "L2: Scenario Scene",
        3 => "L3: Persona & Skill"
      }.freeze

      module_function

      def normalize_layer(layer)
        case layer.to_s.downcase
        when "0", "l0", "raw"     then L0_RAW
        when "1", "l1", "atom"    then L1_ATOMS
        when "2", "l2", "scene"   then L2_SCENES
        when "3", "l3", "persona" then L3_PERSONA
        else L1_ATOMS
        end
      end

      def name_for(layer)
        LAYER_NAMES[normalize_layer(layer)]
      end

      def tag_for(layer)
        "layer:l#{normalize_layer(layer)}"
      end
    end
  end
end
