# frozen_string_literal: true

module Agentkit
  class Flow
    # Serialisation across job boundaries.
    #
    # In sync mode a step's output stays in memory, so anything works. The
    # moment steps run in different processes, whatever a step returns has to
    # survive a round trip through JSONB — and come back as the same kind of
    # object, not as a hash that looks like it.
    #
    # Job arguments are always `(run_uuid, step_id)`. Domain objects travel in
    # the step row, coded here. That is what stops the classic bug of a job
    # executing against a stale copy of a record.
    module Coder
      RECORD_KEY   = "$record"
      MEMORY_KEY   = "$memory"
      RESULT_KEY   = "$result"
      BRANCHES_KEY = "$branches"
      ARTIFACT_KEY = "$artifact"
      SYMBOL_KEY   = "$sym"
      TIME_KEY     = "$time"

      module_function

      # @param store [#put_artifact] used when the payload exceeds the inline limit
      def dump(value, store: nil)
        coded = encode(value)
        return coded if store.nil?

        oversized?(coded) ? offload(coded, store) : coded
      end

      def load(value, store: nil)
        decode(value, store)
      end

      # ─── Encoding ────────────────────────────────────────────────────────────

      def encode(value)
        case value
        when nil, true, false, Numeric, String then value
        when Symbol then { SYMBOL_KEY => value.to_s }
        when Time   then { TIME_KEY => value.iso8601 }
        when Array  then value.map { |v| encode(v) }
        when Hash   then value.to_h { |k, v| [k.to_s, encode(v)] }
        when StepResults
          { BRANCHES_KEY => value.keys.map(&:to_s),
            "results" => value.results.map { |r| encode(r) } }
        when Result
          { RESULT_KEY => value.ok?, "value" => encode(value.value),
            "error" => value.error&.to_s, "usage" => value.usage&.to_h }
        when Agentkit::Memory::Record
          { MEMORY_KEY => value.id }
        else
          encode_object(value)
        end
      end

      def encode_object(value)
        # ActiveRecord (or anything with a class + id) travels as a reference and
        # is reloaded on the other side, so the worker always sees current data.
        return { RECORD_KEY => value.class.name, "id" => value.id } if value.respond_to?(:id) && value.respond_to?(:persisted?)
        return { RECORD_KEY => value.class.name, "id" => value.id } if value.respond_to?(:id) && value.class.respond_to?(:find_by)

        value.respond_to?(:to_h) ? encode(value.to_h) : value.to_s
      end

      # ─── Decoding ────────────────────────────────────────────────────────────

      def decode(value, store = nil)
        case value
        when Array then value.map { |v| decode(v, store) }
        when Hash  then decode_hash(value, store)
        else value
        end
      end

      def decode_hash(hash, store)
        return decode(fetch_artifact(hash[ARTIFACT_KEY], store), store) if hash.key?(ARTIFACT_KEY)
        return hash[SYMBOL_KEY].to_sym if hash.key?(SYMBOL_KEY)
        return Time.parse(hash[TIME_KEY]) if hash.key?(TIME_KEY)
        return Agentkit::Memory.find(hash[MEMORY_KEY], scope: Scope.resolve) if hash.key?(MEMORY_KEY)
        return find_record(hash[RECORD_KEY], hash["id"]) if hash.key?(RECORD_KEY)

        if hash.key?(BRANCHES_KEY)
          keys    = hash[BRANCHES_KEY]
          results = Array(hash["results"]).map { |r| decode(r, store) }
          return StepResults.new(keys.zip(results))
        end

        if hash.key?(RESULT_KEY)
          value = decode(hash["value"], store)
          return Result.ok(value) if hash[RESULT_KEY]

          return Result.err(FlowError.new(hash["error"].to_s))
        end

        hash.to_h { |k, v| [k, decode(v, store)] }
      end

      def find_record(class_name, id)
        klass = Object.const_get(class_name)
        klass.respond_to?(:find_by) ? klass.find_by(id: id) : nil
      rescue NameError, StandardError
        { RECORD_KEY => class_name, "id" => id } # keep the reference rather than lose it
      end

      # ─── Artifacts ───────────────────────────────────────────────────────────

      # A 200 KB screenplay does not belong in a JSONB column, and definitely not
      # in job arguments.
      def oversized?(coded)
        JSON.generate(coded).bytesize > Agentkit.config.flow.max_inline_payload
      rescue StandardError
        false
      end

      def offload(coded, store)
        return coded unless store.respond_to?(:put_artifact)

        { ARTIFACT_KEY => store.put_artifact(coded) }
      end

      def fetch_artifact(id, store)
        return nil if store.nil? || !store.respond_to?(:get_artifact)

        store.get_artifact(id)
      end
    end
  end
end
