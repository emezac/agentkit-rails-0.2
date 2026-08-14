# frozen_string_literal: true

module Agentkit
  module TeamMemory
    # Extract reusable skills from conversation transcripts or agent interaction logs.
    class SkillExtractor
      class << self
        def extract(conversation:, name: nil, team_id: nil, visibility: "team")
          messages = format_messages(conversation)
          name ||= "extracted_skill_#{Time.now.to_i}"

          # Extract skill definition structures from text
          steps = extract_steps(messages)
          triggers = extract_triggers(messages)
          prompt_fragment = build_prompt_fragment(name, steps, triggers)

          # Store as a Team Memory Skill Asset
          asset = AssetStore.create(
            asset_type: "skill",
            name: name,
            team_id: team_id,
            visibility: visibility,
            content: {
              "name"               => name,
              "steps"              => steps,
              "triggers"           => triggers,
              "prompt_fragment"   => prompt_fragment,
              "extracted_at"      => Time.now.iso8601
            }
          )

          # Register into SkillRegistry if defined
          if defined?(Agentkit::Skill)
            Agentkit::Skill.define(name) do |s|
              s.prompt(prompt_fragment)
            end
          end

          asset
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
          steps.empty? ? ["Analyze user prompt", "Execute domain logic", "Verify result"] : steps.uniq
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
