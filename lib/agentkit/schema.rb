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
      if (expected = schema["type"])
        allowed = Array(expected).filter_map { |type| TYPE_CLASSES[type.to_s] }.flatten
        violations << "#{path}: expected #{Array(expected).join(' or ')}" unless allowed.any? { |klass| value.is_a?(klass) }
        return violations if violations.any?
      end
      if schema.key?("enum") && !schema["enum"].include?(value)
        violations << "#{path}: must be one of #{schema['enum'].inspect}"
      end
      if value.is_a?(Hash)
        object = value.each_with_object({}) { |(key, item), result| result[key.to_s] = item }
        Array(schema["required"]).map(&:to_s).each do |key|
          violations << "#{path}.#{key}: is required" unless object.key?(key)
        end
        properties = schema["properties"] || {}
        if schema["additionalProperties"] == false
          (object.keys - properties.keys).each { |key| violations << "#{path}.#{key}: additional property is not allowed" }
        end
        properties.each do |key, child|
          violations.concat(validate(object[key], child, path: "#{path}.#{key}")) if object.key?(key)
        end
      elsif value.is_a?(Array) && schema["items"]
        value.each_with_index { |item, index| violations.concat(validate(item, schema["items"], path: "#{path}[#{index}]")) }
      end
      violations
    end

    def deep_stringify(value)
      case value
      when Hash then value.each_with_object({}) { |(key, item), result| result[key.to_s] = deep_stringify(item) }
      when Array then value.map { |item| deep_stringify(item) }
      else value
      end
    end
  end
end
