# frozen_string_literal: true

module Agentkit
  # Kernel-level JSON Schema subset. Protocol adapters may validate too, but
  # every entry point uses this contract before reaching domain code.
  module Schema
    TYPE_CLASSES = {
      "string" => String, "integer" => Integer, "number" => Numeric,
      "object" => Hash, "array" => Array,
      "boolean" => [TrueClass, FalseClass], "null" => NilClass
    }.freeze
    MAX_TOOL_ISSUES = 6
    MAX_TOOL_ISSUE_PATH_BYTES = 120

    module_function

    def normalize(schema)
      value = if schema.respond_to?(:json_schema)
                schema.json_schema
              elsif schema.respond_to?(:schema)
                schema.schema
              else
                schema
              end
      deep_stringify(value || {})
    end

    def validate!(value, schema, label: "value")
      violations = validate(value, normalize(schema), path: "$")
      raise SchemaValidationError.new("#{label} schema validation failed", violations: violations) if violations.any?

      value
    end

    def validate(value, schema, path:)
      violations = []
      each_violation(value, schema, path: path) do |field, rule, detail|
        violations << case rule
                      when "type" then "#{field}: expected #{detail.join(' or ')}"
                      when "enum" then "#{field}: must be one of #{detail.inspect}"
                      when "required" then "#{field}: is required"
                      when "additional_properties" then "#{field}.#{detail}: additional property is not allowed"
                      end
      end
      violations
    end

    # Model-facing diagnostics name only paths declared by the offered schema.
    # Unknown property names, input values and enum contents are omitted.
    def tool_input_issues(value, schema)
      issues = []
      each_violation(value, normalize(schema), path: "$") do |path, rule, detail|
        safe_path = if path.bytesize <= MAX_TOOL_ISSUE_PATH_BYTES && path.match?(/\A\$[a-zA-Z0-9_.\[\]-]*\z/)
                      path
                    else
                      "$"
                    end
        issue = { "path" => safe_path, "rule" => rule }
        if rule == "type"
          types = detail.map(&:to_s).uniq & TYPE_CLASSES.keys
          issue["expected_types"] = types if types.any?
        end
        issues << issue unless issues.include?(issue)
        return issues if issues.size >= MAX_TOOL_ISSUES
      end
      issues
    end

    def each_violation(value, schema, path:, &block)
      if (expected = schema["type"])
        types = Array(expected)
        allowed = types.filter_map { |type| TYPE_CLASSES[type.to_s] }.flatten
        unless allowed.any? { |klass| value.is_a?(klass) }
          yield path, "type", types
          return
        end
      end
      if schema.key?("enum") && !schema["enum"].include?(value)
        yield path, "enum", schema["enum"]
      end
      if value.is_a?(Hash)
        object = value.each_with_object({}) { |(key, item), result| result[key.to_s] = item }
        Array(schema["required"]).map(&:to_s).each do |key|
          yield "#{path}.#{key}", "required", nil unless object.key?(key)
        end
        properties = schema["properties"] || {}
        if schema["additionalProperties"] == false
          (object.keys - properties.keys).each { |key| yield path, "additional_properties", key }
        end
        properties.each do |key, child|
          each_violation(object[key], child, path: "#{path}.#{key}", &block) if object.key?(key)
        end
      elsif value.is_a?(Array) && schema["items"]
        value.each_with_index { |item, index| each_violation(item, schema["items"], path: "#{path}[#{index}]", &block) }
      end
    end
    private_class_method :each_violation

    def deep_stringify(value)
      case value
      when Hash then value.each_with_object({}) { |(key, item), result| result[key.to_s] = deep_stringify(item) }
      when Array then value.map { |item| deep_stringify(item) }
      else value
      end
    end
  end
end
