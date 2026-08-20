# frozen_string_literal: true

require "json"
require "yaml"
require "digest"

module Agentkit
  # Export and import Skills as portable bundles with markdown frontmatter and JSON specifications.
  module SkillExport
    SCHEMA_VERSION = 1
    MAX_SKILL_BYTES = 128 * 1024
    MAX_TOOLS_BYTES = 64 * 1024
    NAME_PATTERN = /\A[a-zA-Z][a-zA-Z0-9_-]{0,63}\z/

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
      # Import validates completely, then creates a non-executable quarantined
      # asset and a separate HITL activation proposal.
      def import(bundle, origin: nil, author: nil, importer: nil)
        md_text = bundle["SKILL.md"] || bundle[:"SKILL.md"] || bundle["markdown"]
        raise ConfigurationError, "Invalid skill bundle: missing SKILL.md content" if md_text.nil?
        raise ConfigurationError, "SKILL.md exceeds #{MAX_SKILL_BYTES} bytes" if md_text.to_s.bytesize > MAX_SKILL_BYTES

        tools_text = bundle["tools.json"] || bundle[:"tools.json"]
        raise ConfigurationError, "Invalid skill bundle: missing tools.json" if tools_text.nil?
        raise ConfigurationError, "tools.json exceeds #{MAX_TOOLS_BYTES} bytes" if tools_text.to_s.bytesize > MAX_TOOLS_BYTES
        tools = JSON.parse(tools_text.to_s)
        raise ConfigurationError, "tools.json must contain a JSON object" unless tools.is_a?(Hash)

        metadata, prompt_fragment = parse_skill_md(md_text)
        name = metadata.fetch("name").to_s
        version = metadata.fetch("version", "1.0.0").to_s
        schema_version = Integer(metadata.fetch("schema_version", SCHEMA_VERSION))
        raise ConfigurationError, "Unsupported skill schema_version: #{schema_version}" unless schema_version == SCHEMA_VERSION
        raise ConfigurationError, "Invalid skill name: #{name.inspect}" unless NAME_PATTERN.match?(name)

        existing = TeamMemory::AssetStore.find_by_name(name, asset_type: "skill")
        if existing && existing.version == version && existing.status != "archived"
          raise ConfigurationError, "Skill #{name} version #{version} already exists"
        end

        digest = bundle_digest(md_text.to_s, tools_text.to_s)
        content = {
          "schema_version" => schema_version, "name" => name, "version" => version,
          "prompt_fragment" => prompt_fragment, "tools" => tools,
          "digest" => digest, "origin" => origin, "author" => author,
          "importer" => importer
        }.compact

        asset = TeamMemory.create_asset(
          asset_type: "skill", name: name, version: version, status: "quarantined",
          visibility: "restricted", content: content
        )
        suggestion = HITL.suggest!(
          type: "skill_activation", title: "Activate imported skill: #{name}",
          description: "Review imported skill #{name} #{version} (#{digest}).",
          priority: "high", source_agent: "SkillExport", payload: { "asset_id" => asset.id, "digest" => digest },
          idempotency_key: "skill-activation:#{digest}", metadata: { "arguments_digest" => HITL.send(:canonical_digest, { "asset_id" => asset.id, "digest" => digest }) }
        )
        HITL.on("skill_activation") do |approved|
          next unless approved.id == suggestion.id

          activate(asset, approver: approved.metadata["decision_actor"] || "human", expected_digest: digest)
        end

        asset
      end

      def activate(asset, approver:, expected_digest: nil)
        raise ConfigurationError, "Only quarantined or reviewed skills can be activated" unless %w[quarantined reviewed].include?(asset.status)
        digest = asset.content["digest"]
        raise ConfigurationError, "Skill digest changed after review" if expected_digest && digest != expected_digest

        skill = Skill.define(asset.name) { |s| s.prompt(asset.content.fetch("prompt_fragment")) }
        reviewed = asset.content.merge("approved_by" => approver.to_s, "approved_at" => Time.now.iso8601)
        TeamMemory::AssetStore.update(asset, status: "active", content: reviewed)
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
          schema_version: #{SCHEMA_VERSION}
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
        match = md_text.to_s.match(/\A---\s*\n(.*?)\n---\s*\n(.*)\z/m)
        raise ConfigurationError, "Invalid SKILL.md frontmatter" unless match

        metadata = YAML.safe_load(match[1], permitted_classes: [], permitted_symbols: [], aliases: false)
        raise ConfigurationError, "SKILL.md frontmatter must be a mapping" unless metadata.is_a?(Hash)
        raise ConfigurationError, "SKILL.md frontmatter requires name" if metadata["name"].to_s.empty?

        [metadata, match[2].strip]
      rescue Psych::Exception => e
        raise ConfigurationError, "Unsafe SKILL.md frontmatter: #{e.message}"
      end


      def bundle_digest(md_text, tools_text)
        "sha256:#{Digest::SHA256.hexdigest([md_text, tools_text].join("\0"))}"
      end
    end
  end
end
