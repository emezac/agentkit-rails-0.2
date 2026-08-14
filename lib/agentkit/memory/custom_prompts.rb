# frozen_string_literal: true

module Agentkit
  module Memory
    # CustomPrompts manager for user-, account-, or team-specific memory extraction and recall prompts.
    class CustomPrompts
      class << self
        def registry
          @registry ||= {}
        end

        def register(scope_key, prompt_type:, template:, version: "1.0.0")
          key = build_key(scope_key, prompt_type)
          registry[key] = {
            template: template.to_s,
            version: version.to_s,
            registered_at: Time.now.iso8601
          }
        end

        def render(scope_key, prompt_type:, default_template:, context: {})
          key = build_key(scope_key, prompt_type)
          config = registry[key]

          template = config ? config[:template] : default_template
          version  = config ? config[:version] : "default"

          rendered = template.dup
          context.each do |k, v|
            rendered.gsub!("{#{k}}", v.to_s)
          end

          [rendered, version]
        end

        def reset!
          @registry = {}
        end

        private

        def build_key(scope_key, prompt_type)
          "#{scope_key}:#{prompt_type}"
        end
      end
    end
  end
end
