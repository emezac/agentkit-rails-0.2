# frozen_string_literal: true

module Agentkit
  # Discovery discloses authorized schemas, never grants execution permissions.
  class ToolCatalog
    RESERVED = %w[load_skill search_tools].freeze
    attr_reader :entries

    def initialize(tools:, context:, settings:, policies: [], authorize: nil)
      @context, @settings, @policies, @authorize = context, settings, policies, authorize
      @entries, @exposed = {}, {}
      raise ConfigurationError, "too many catalog tools" if tools.size > settings.max_catalog_tools
      tools.each do |tool|
        tool = SkillRegistry.tool(tool.to_sym) if tool.is_a?(String) || tool.is_a?(Symbol)
        raise ConfigurationError, "loop tools must implement ToolContract" unless tool.is_a?(ToolContract)
        name = tool.name.to_s
        unless name.match?(/\A[a-zA-Z0-9_-]{1,64}\z/) && !RESERVED.include?(name) && !entries.key?(name)
          raise ConfigurationError, "duplicate, invalid or reserved loop tool name"
        end
        @entries[name] = { tool: tool, digest: tool.contract_digest,
                           schema: Harness.deep_freeze(Harness::DeclarativeData.normalize(
                             { name: name, description: tool.description, input_schema: tool.input_schema },
                             label: "loop tool schema"
                           )) }.freeze
      end
      @entries.freeze
    end

    def permitted?(tool)
      name = tool.name.to_s
      policy_allows = @policies.all? do |policy|
        allow = policy[:allow] || policy["allow"]
        deny = policy[:deny] || policy["deny"] || []
        (allow.nil? || allow.map(&:to_s).include?(name)) && !deny.map(&:to_s).include?(name)
      end
      policy_allows && (!@authorize || @authorize.call(tool, @context) == true)
    rescue StandardError
      false
    end

    def search(query:, limit: 5)
      unless limit.is_a?(Integer) && limit.between?(1, @settings.max_tools)
        raise ArgumentError, "invalid tool search limit"
      end
      terms = query.to_s.downcase.scan(/[[:alnum:]_-]{2,}/).uniq
      matches = entries.values.select { |entry| permitted?(entry[:tool]) && integrity!(entry) }.map do |entry|
        text = "#{entry[:schema]['name']} #{entry[:schema]['description']}".downcase
        [entry, terms.count { |term| text.include?(term) }]
      end.select { |_, score| score.positive? }
      chosen = matches.sort_by { |entry, score| [-score, entry[:schema]["name"]] }.first(limit).map(&:first)
      activate!(chosen.map { |entry| entry[:tool].name.to_s })
      chosen.map { |entry| entry.fetch(:schema) }
    end

    def activate!(names)
      selected = names.map do |name|
        entry = entries.fetch(name.to_s) { raise ToolExecutionDenied, "tool is unavailable" }
        raise ToolExecutionDenied, "tool is unavailable" unless permitted?(entry[:tool])
        integrity!(entry)
        entry
      end
      if (@exposed.keys | names.map(&:to_s)).size > @settings.max_tools
        raise AgentLoopLimitExceeded, "too many active tools"
      end
      selected.each { |entry| @exposed[entry[:tool].name.to_s] = entry }
      schemas
    end

    def schemas
      @exposed.values.select { |entry| permitted?(entry[:tool]) && integrity!(entry) }.map { |entry| entry[:schema] }
    end

    def names = schemas.map { |schema| schema.fetch("name") }
    def exposed_names = @exposed.keys.dup

    def fetch_exposed!(name, offered:)
      entry = @exposed[name.to_s]
      unless offered.include?(name.to_s) && entry && permitted?(entry[:tool])
        raise ToolExecutionDenied, "tool is unavailable"
      end
      integrity!(entry)
      entry.fetch(:tool)
    end

    private

    def integrity!(entry)
      unless entry[:tool].contract_digest == entry[:digest]
        raise HarnessIntegrityError, "tool contract changed during loop"
      end
      true
    end
  end
end
