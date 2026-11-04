# frozen_string_literal: true

module Agentkit
  module TeamMemory
    # Extract reusable skills from conversation transcripts or agent interaction logs.
    class SkillExtractor
      class << self
        def extract(conversation:, name: nil, team_id: nil, visibility: "team")
          messages = format_messages(conversation)
          raise ArgumentError, "a real conversation with at least two messages is required" if messages.size < 2
          name ||= "extracted_skill_#{Time.now.to_i}"

          # Extract skill definition structures from text
          steps = extract_steps(messages)
          raise ArgumentError, "conversation contains no explicit procedure steps" if steps.empty?
          triggers = extract_triggers(messages)
          prompt_fragment = build_prompt_fragment(name, steps, triggers)

          # Store as a Team Memory Skill Asset
          asset = AssetStore.create(
            asset_type: "skill",
            name: name,
            team_id: team_id,
            visibility: "restricted",
            status: "quarantined",
            content: {
              "name"               => name,
              "steps"              => steps,
              "triggers"           => triggers,
              "prompt_fragment"   => prompt_fragment,
              "extracted_at"      => Time.now.iso8601,
              "requested_visibility" => visibility.to_s
            }
          )

          asset
        end

        # The Rails host authenticates the reviewer in authorize; extracted text
        # never registers itself as an executable procedure.
        def review_and_activate!(asset, actor:, authorize:)
          raise ArgumentError, "reviewer is required" if actor.to_s.strip.empty?
          stored = AssetStore.find(asset.id)
          raise ConfigurationError, "skill candidate is unavailable" unless stored &&
            stored.asset_type == "skill" && stored.status == "quarantined"
          raise ConfigurationError, "skill review denied" unless authorize.call(stored, actor) == true

          approved = AssetStore.update(stored, status: "active",
            content: stored.content.merge("approved_by" => actor.to_s, "approved_at" => Time.now.iso8601))
          approved || raise(HarnessPersistenceError, "approved skill was not saved")
        end

        private

        def format_messages(conversation)
          if conversation.is_a?(Array)
            conversation.map { |m| m.is_a?(Hash) ? m[:content] || m["content"] : m.to_s }
          elsif conversation.respond_to?(:messages)
            conversation.messages.map(&:to_s)
          else
            conversation.to_s.lines
          end
        end

        def extract_steps(messages)
          steps = []
          messages.each do |msg|
            msg.to_s.scan(/(?:step\s*\d+:?|action:?|first:?|then:?|next:?|finally:?)\s*([^.\n]+)/i).each do |match|
              steps << match.first.strip
            end
          end
          steps.uniq
        end

        def extract_triggers(messages)
          triggers = []
          messages.each do |msg|
            msg.to_s.scan(/(?:when|trigger|if prompt contains):\s*(.+)/i).each do |match|
              triggers << match.first.strip
            end
          end
          triggers.uniq
        end

        def build_prompt_fragment(name, steps, triggers)
          lines = ["## Skill: #{name}"]
          lines << "Triggers: #{triggers.join(', ')}" unless triggers.empty?
          lines << "Execution steps:"
          steps.each_with_index { |s, idx| lines << "#{idx + 1}. #{s}" }
          lines.join("\n")
        end
      end
    end
  end
end
