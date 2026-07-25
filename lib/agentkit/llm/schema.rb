# frozen_string_literal: true

module Agentkit
  module LLM
    # Structured output without a JSON-schema gem.
    #
    # Four of the six v0.1 projects hand-rolled the same `parse_json` with a
    # regex fallback (`tres`, `astra`, `totallook`, `cuatro`). This replaces all
    # of them: declare the shape once, and the LLM layer extracts, validates and
    # re-asks on violation.
    #
    #   ScenarioSchema = Agentkit::LLM::Schema.define do
    #     string :concept,     required: true, min_length: 10
    #     string :application, required: true
    #     number :innovation,  required: true, min: 0, max: 1
    #     array  :tags,        of: :string
    #   end
    #
    #   llm.complete(prompt, schema: ScenarioSchema).parsed
    #   # => { concept: "...", application: "...", innovation: 0.8, tags: [...] }
    class Schema
      Field = Struct.new(:name, :type, :required, :opts, :schema, keyword_init: true)

      def self.define(&block)
        schema = new
        schema.instance_eval(&block)
        schema
      end

      attr_reader :fields

      def initialize
        @fields = {}
      end

      def string(name, required: false, **opts)  = add(name, :string,  required, opts)
      def number(name, required: false, **opts)  = add(name, :number,  required, opts)
      def integer(name, required: false, **opts) = add(name, :integer, required, opts)
      def boolean(name, required: false, **opts) = add(name, :boolean, required, opts)
      def array(name, required: false, **opts)   = add(name, :array,   required, opts)

      def object(name, required: false, **opts, &block)
        add(name, :object, required, opts, block ? Schema.define(&block) : nil)
      end

      # Root-level array of objects: `schema.items { string :x }`
      def items(&block)
        @items = Schema.define(&block)
        self
      end
      attr_reader :items_schema

      # ─── Validation ────────────────────────────────────────────────────────

      # @return [Array<String>] human-readable violations; empty means valid
      def validate(data)
        return ["expected an object, got #{data.class}"] unless data.is_a?(Hash)

        data = symbolize(data)
        violations = []

        fields.each_value do |f|
          value = data[f.name]
          if value.nil?
            violations << "missing required field `#{f.name}`" if f.required
            next
          end
          violations.concat(validate_field(f, value))
        end
        violations
      end

      def valid?(data) = validate(data).empty?

      # Cast strings to the declared types where unambiguous, so a model that
      # answers "0.8" instead of 0.8 does not trigger a pointless re-ask.
      def coerce(data)
        return data unless data.is_a?(Hash)

        symbolize(data).each_with_object({}) do |(k, v), acc|
          f = fields[k]
          acc[k] = f ? cast(f, v) : v
        end
      end

      # ─── Provider-facing JSON Schema ───────────────────────────────────────

      def to_json_schema
        {
          type: "object",
          properties: fields.values.to_h { |f| [f.name.to_s, json_type(f)] },
          required: fields.values.select(&:required).map { |f| f.name.to_s },
          additionalProperties: false
        }
      end

      # Instruction block appended to the system prompt for providers without
      # native structured output (most OpenAI-compatible gateways).
      def prompt_fragment
        <<~TXT.strip
          Respond with a single valid JSON object and nothing else — no prose,
          no markdown fences. It must satisfy this schema:
          #{JSON.pretty_generate(to_json_schema)}
        TXT
      end

      # ─── Extraction ────────────────────────────────────────────────────────

      # Pull a JSON object out of whatever the model actually returned. Handles
      # fenced blocks, leading prose and trailing commentary — the three failure
      # modes each project rediscovered on its own.
      def self.extract(raw)
        return raw if raw.is_a?(Hash) || raw.is_a?(Array)

        text = raw.to_s.strip
        return nil if text.empty?

        cleaned = text.gsub(/\A```(?:json)?\s*/i, "").gsub(/```\s*\z/, "").strip
        try_parse(cleaned) || try_parse(balanced_slice(cleaned, "{", "}")) ||
          try_parse(balanced_slice(cleaned, "[", "]"))
      end

      def self.try_parse(candidate)
        return nil if candidate.nil? || candidate.empty?

        JSON.parse(candidate)
      rescue JSON::ParserError
        nil
      end

      # Finds the first balanced {...} / [...] region, tolerating braces inside
      # strings — a plain greedy regex mis-slices nested payloads.
      def self.balanced_slice(text, open_char, close_char)
        start = text.index(open_char)
        return nil unless start

        depth = 0
        in_string = false
        escaped = false
        text[start..].each_char.with_index do |ch, i|
          if in_string
            if escaped     then escaped = false
            elsif ch == "\\" then escaped = true
            elsif ch == '"'  then in_string = false
            end
            next
          end

          case ch
          when '"'        then in_string = true
          when open_char  then depth += 1
          when close_char
            depth -= 1
            return text[start, i + 1] if depth.zero?
          end
        end
        nil
      end

      private

      def add(name, type, required, opts, schema = nil)
        @fields[name.to_sym] = Field.new(name: name.to_sym, type: type, required: required,
                                         opts: opts, schema: schema)
        self
      end

      def validate_field(field, value)
        v = []
        case field.type
        when :string
          return ["`#{field.name}` must be a string"] unless value.is_a?(String)

          v << "`#{field.name}` shorter than #{field.opts[:min_length]}" if field.opts[:min_length] && value.length < field.opts[:min_length]
          v << "`#{field.name}` not in #{field.opts[:in].inspect}" if field.opts[:in] && !field.opts[:in].map(&:to_s).include?(value)
        when :number, :integer
          return ["`#{field.name}` must be a number"] unless value.is_a?(Numeric)

          v << "`#{field.name}` must be an integer" if field.type == :integer && !value.is_a?(Integer)
          v << "`#{field.name}` below #{field.opts[:min]}" if field.opts[:min] && value < field.opts[:min]
          v << "`#{field.name}` above #{field.opts[:max]}" if field.opts[:max] && value > field.opts[:max]
        when :boolean
          v << "`#{field.name}` must be a boolean" unless [true, false].include?(value)
        when :array
          return ["`#{field.name}` must be an array"] unless value.is_a?(Array)

          v << "`#{field.name}` needs at least #{field.opts[:min_items]} items" if field.opts[:min_items] && value.size < field.opts[:min_items]
          if field.schema
            value.each_with_index { |item, i| v.concat(field.schema.validate(item).map { |m| "#{field.name}[#{i}]: #{m}" }) }
          end
        when :object
          return ["`#{field.name}` must be an object"] unless value.is_a?(Hash)

          v.concat(field.schema.validate(value).map { |m| "#{field.name}.#{m}" }) if field.schema
        end
        v
      end

      def cast(field, value)
        case field.type
        when :number  then value.is_a?(String) && value.match?(/\A-?\d+(\.\d+)?\z/) ? value.to_f : value
        when :integer then value.is_a?(String) && value.match?(/\A-?\d+\z/) ? value.to_i : value
        when :boolean then %w[true false].include?(value.to_s) ? value.to_s == "true" : value
        when :object  then field.schema ? field.schema.coerce(value) : value
        when :array
          field.schema && value.is_a?(Array) ? value.map { |i| field.schema.coerce(i) } : value
        else value
        end
      end

      def json_type(field)
        base = case field.type
               when :string  then { type: "string" }
               when :number  then { type: "number" }
               when :integer then { type: "integer" }
               when :boolean then { type: "boolean" }
               when :array   then { type: "array", items: field.schema&.to_json_schema || { type: "string" } }
               when :object  then field.schema&.to_json_schema || { type: "object" }
               end
        base[:enum] = field.opts[:in] if field.opts[:in]
        base
      end

      def symbolize(hash)
        hash.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
      end
    end
  end
end
