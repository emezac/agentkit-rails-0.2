# frozen_string_literal: true

require "json"

module Agentkit
  # Export and import Skills as portable bundles with markdown frontmatter and JSON specifications.
  module SkillExport
    class << self
      # Export a skill definition to a structured bundle hash or zip-compatible file payload.
      #
      # @param skill_or_name [Agentkit::Skill, Symbol, String] Skill object or skill name
      # @return [Hash] Export bundle ({ "SKILL.md" => content, "tools.json" => content })
      def export(skill_or_name)
        skill = resolve_skill(skill_or_name)

        md_content = build_skill_md(skill)
        tools_content = build_tools_json(skill)

        {
          "SKILL.md"   => md_content,
          "tools.json" => tools_content,
          "metadata"   => {
            "name"         => skill.name.to_s,
            "exported_at"  => Time.now.iso8601,
            "agentkit_v"   => Agentkit::VERSION
          }.to_json
        }
      end

      # Import a skill bundle hash back into Agentkit::SkillRegistry and TeamMemory
      #
      # @param bundle [Hash] Hash containing "SKILL.md" or skill metadata
      # @return [Agentkit::Skill] The registered skill instance
      def import(bundle)
        md_text = bundle["SKILL.md"] || bundle[:"SKILL.md"] || bundle["markdown"]
        raise ConfigurationError, "Invalid skill bundle: missing SKILL.md content" if md_text.nil?

        name, prompt_fragment = parse_skill_md(md_text)

        skill = Skill.define(name) do |s|
          s.prompt(prompt_fragment)
        end

        if defined?(TeamMemory)
          TeamMemory.create_asset(
            asset_type: "skill",
            name: name.to_s,
            visibility: "team",
            content: { "name" => name.to_s, "prompt_fragment" => prompt_fragment }
          )
        end

        skill
      end

      private

      def resolve_skill(skill_or_name)
        if skill_or_name.is_a?(Skill)
          skill_or_name
        elsif defined?(SkillRegistry)
          SkillRegistry.load_skill(skill_or_name)
        else
          Skill.new(skill_or_name)
        end
      end

      def build_skill_md(skill)
        prompt_text = skill.respond_to?(:system_prompt_fragment) ? skill.system_prompt_fragment(nil) : ""
        <<~MARKDOWN
          ---
          name: #{skill.name}
          description: Skill bundle for #{skill.name}
          version: 1.0.0
          ---

          #{prompt_text}
        MARKDOWN
      end

      def build_tools_json(skill)
        tools = skill.respond_to?(:tools) ? skill.tools : {}
        schemas = tools.transform_values do |t|
          t.respond_to?(:to_json_schema) ? t.to_json_schema : t.to_s
        end
        JSON.pretty_generate(schemas)
      end

      def parse_skill_md(md_text)
        name = "imported_skill_#{Time.now.to_i}"
        prompt_body = md_text.to_s

        if md_text =~ /\A---\s*\n(.*?)\n---\s*\n(.*)/m
          frontmatter = Regexp.last_match(1)
          prompt_body = Regexp.last_match(2)

          if frontmatter =~ /name:\s*(.+)/
            name = Regexp.last_match(1).strip
          end
        end

        [name.to_sym, prompt_body.strip]
      end
    end
  end
end
