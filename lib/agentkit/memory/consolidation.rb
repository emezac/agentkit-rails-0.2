# frozen_string_literal: true

module Agentkit
  module Memory
    # Reviewed representations over host-owned evidence. Never a source of
    # permissions, causal proof or executable instructions.
    class Consolidation
      K = Knowledge
      B = K::Boundary
      SOURCE_KINDS = %w[record tool_result document user_statement model_output].freeze

      def initialize(journal:, authorize:, loader:, verifier:, verifier_version:, clock: -> { Time.now.utc })
        raise K::InvalidContract, "trusted callbacks required" unless [authorize, loader, verifier, clock].all? { |v| v.respond_to?(:call) }
        @journal, @authorize, @loader, @verifier, @clock = journal, authorize, loader, verifier, clock
        @verifier_version = K.text(verifier_version)
      end

      def propose(id:, topic:, sources:, claims:, context:, kind: "note", ttl: 86_400)
        guard!("propose", context)
        raise K::InvalidContract, "invalid representation kind or TTL" unless %w[note wiki].include?(kind) && ttl.is_a?(Integer) && ttl.between?(1, 31_536_000)
        request = B.data(id: identifier(id), topic: identifier(topic), sources: sources, claims: claims, kind: kind, ttl: ttl,
          creator: B.identity(context).fetch("principal"), verifier_version: @verifier_version)
        validate!(request)
        @journal.once(kind: "memory", key: key("candidate", id), request_digest: K.digest(request), context: context) do
          loaded = load_sources(request.fetch("sources"), context)
          request.fetch("claims").each do |claim|
            claim.fetch("evidence").each do |ref|
              source = loaded.fetch(ref.fetch("source_id"))
              raise K::InvalidContract, "quote is not in the declared source" unless source.fetch("content").include?(ref.fetch("quote"))
            end
          end
          request.merge("sources" => request.fetch("sources").map { |s| s.merge("observed_at" => loaded.fetch(s.fetch("id")).fetch("observed_at")) },
            "status" => "candidate", "created_at" => now.iso8601(6), "expires_at" => (now + ttl).iso8601(6),
            "authorizes" => false, "causal_proof" => false)
        end
      end

      def candidate(id:, context:)
        guard!("read_history", context)
        @journal.read(kind: "memory", key: key("candidate", identifier(id)), context: context)
      end

      # Host authorization must require a human reviewer. The independent actor
      # check is additional protection, not proof that an identity is human.
      def publish(id:, expected_revision:, reason:, context:)
        guard!("publish", context)
        raise K::InvalidContract, "nonnegative expected revision required" unless expected_revision.is_a?(Integer) && expected_revision >= 0
        item = candidate(id: id, context: context) || raise(K::InvalidContract, "unknown candidate")
        actor = B.identity(context).fetch("principal")
        raise K::AccessDenied, "independent reviewer required" if actor == item.fetch("creator")
        raise K::IntegrityError, "verifier changed; propose a new candidate" unless item.fetch("verifier_version") == @verifier_version
        request = B.data(candidate_digest: K.digest(item), expected_revision: expected_revision, actor: actor, reason: bounded_text(reason))
        result = model.transaction(requires_new: true) do
          @journal.once(kind: "memory", key: key("publication", id), request_digest: K.digest(request), context: context) do
            row = heads(context).create_or_find_by!(topic_key: key(item.fetch("topic")))
            row.lock!
            guard!("publish", context)
            raise K::IntegrityError, "memory revision conflict" unless row.revision == expected_revision
            reasons = dependency_reasons(item, context)
            if reasons.empty?
              begin
                verdict = B.data(@verifier.call(K.copy(item.merge("source_contents" => load_sources(item.fetch("sources"), context))), context))
                K::Snapshot.exact_keys!(verdict, %w[accepted reasons])
                unless [true, false].include?(verdict["accepted"]) && verdict["reasons"].is_a?(Array) && verdict["reasons"].size <= 32 && verdict["reasons"].all? { |r| r.is_a?(String) && r.bytesize <= 1024 }
                  raise K::InvalidContract, "invalid verification verdict"
                end
                reasons.concat(verdict["reasons"])
                reasons << "verification_rejected" unless verdict["accepted"]
              rescue K::AccessDenied
                raise
              rescue StandardError => error
                reasons << "verifier_unavailable:#{error.class.name}"
              end
            end
            if reasons.any?
              request.merge("status" => "rejected", "reasons" => reasons, "authorizes" => false, "causal_proof" => false)
            else
              write_revision(row, item.merge("status" => "active", "reviewer" => actor, "review_reason" => reason,
                "verified_at" => now.iso8601(6)), context)
            end
          end
        end
        result || raise(K::IntegrityError, "publication transaction rolled back")
      end

      # Historical state, NOT a fresh retrieval clearance.
      def head(topic:, context:)
        guard!("read_history", context)
        row = heads(context).find_by(topic_key: key(identifier(topic)))
        row && read_revision(row, context)
      end

      def revision(topic:, number:, context:)
        guard!("read_history", context)
        raise K::InvalidContract, "positive revision number required" unless number.is_a?(Integer) && number.positive?
        @journal.read(kind: "memory", key: key("revision", key(identifier(topic)), number), context: context)
      end

      def revoke(topic:, expected_revision:, reason:, context:)
        guard!("revoke", context)
        reason = bounded_text(reason)
        row = heads(context).find_by!(topic_key: key(identifier(topic)))
        result = row.with_lock do
          guard!("revoke", context)
          raise K::IntegrityError, "memory revision conflict" unless expected_revision.is_a?(Integer) && row.revision == expected_revision
          item = read_revision(row, context) || raise(K::InvalidContract, "unpublished topic")
          write_revision(row, item.merge("status" => "revoked", "reasons" => [reason], "revoked_by" => B.identity(context).fetch("principal")), context)
        end
        result || raise(K::IntegrityError, "revocation transaction rolled back")
      end

      # Every retrieval rechecks source permissions, exact content/version and
      # freshness. Source failures exclude the representation, never validate it.
      def current(topic:, context:)
        guard!("read", context)
        row = heads(context).find_by(topic_key: key(identifier(topic)))
        return nil unless row
        completed = false
        result = row.with_lock do
          guard!("read", context)
          item = read_revision(row, context)
          if item && item["status"] == "active"
            reasons = dependency_reasons(item, context)
            if reasons.any?
              write_revision(row, item.merge("status" => "stale", "reasons" => reasons), context)
              item = nil
            end
          else
            item = nil
          end
          completed = true
          item
        end
        raise K::IntegrityError, "retrieval transaction rolled back" unless completed
        result
      end

      # Explicit event-driven invalidation; every affected head gets its own
      # atomic revision. A retry skips already-invalidated revisions.
      def invalidate(reference:, reason:, context:)
        guard!("invalidate", context)
        reference, reason = bounded_text(reference), bounded_text(reason)
        changed = []
        heads(context).find_each do |row|
          committed = row.with_lock do
            guard!("invalidate", context)
            item = read_revision(row, context)
            if item && item["status"] == "active" && item.fetch("sources").any? { |s| s["reference"] == reference }
              updated = write_revision(row, item.merge("status" => "stale", "reasons" => [reason], "invalidated_by" => B.identity(context).fetch("principal")), context)
              changed << { "topic" => updated.fetch("topic"), "revision" => updated.fetch("revision") }
            end
            true
          end
          raise K::IntegrityError, "invalidation transaction rolled back" unless committed
        end
        B.data(changed)
      end

      # A compact pointer index, not truncated assertions and not automatic
      # prompt injection. Fetch current(topic:) when following any pointer.
      def compile_index(topics:, context:, max_bytes: 4096)
        guard!("read", context)
        unless topics.is_a?(Array) && topics.size <= 32 && topics.uniq == topics && max_bytes.is_a?(Integer) && max_bytes.between?(256, 16_384)
          raise K::InvalidContract, "bounded unique topics and byte budget required"
        end
        map, contents, used = Harness::ContextMap.new, {}, 160
        omitted = []
        topics.each do |topic|
          item = current(topic: topic, context: context)
          next unless item
          id = key(topic)
          content = "Topic: #{topic}\nRevision: #{item.fetch('revision')}\nRead current memory before relying on it."
          size = content.bytesize + id.bytesize * 2 + 100
          if used + size > [max_bytes, Agentkit.config.harness.max_context_bytes].min || contents.size >= Agentkit.config.harness.max_context_sources
            omitted << topic
            next
          end
          used += size
          contents[id] = content
          map.source(id, reference: "memory:#{id}", kind: :reviewed_memory_index, always: true, digest: Harness.digest(content), max_bytes: content.bytesize)
        end
        compiled = map.compile(context: context) { |source| contents.fetch(source.id) }
        { compilation: compiled, omitted_topics: omitted.freeze }.freeze
      end

      private

      def now = @clock.call.utc
      def key(*parts) = K.digest(parts)
      def identifier(value)
        value = K.text(value)
        raise K::InvalidContract, "identifier must be 1..128 safe bytes" unless value.bytesize <= 128 && /\A[a-zA-Z0-9:._-]+\z/.match?(value)
        value
      end
      def bounded_text(value)
        value = K.text(value)
        raise K::InvalidContract, "text exceeds 4096 bytes" if value.bytesize > 4096
        value
      end
      def guard!(action, context)
        B.identity(context)
        raise K::AccessDenied, "memory consolidation access denied" unless @authorize.call(action, context) == true
      end
      def model
        unless defined?(Agentkit::MemoryHeadRecord) && Agentkit::MemoryHeadRecord.table_exists?
          raise K::InvalidContract, "memory consolidation requires migration 030"
        end
        raise K::InvalidContract, "memory and Journal must share a pool" unless Agentkit::MemoryHeadRecord.connection_pool.equal?(@journal.model.connection_pool)
        Agentkit::MemoryHeadRecord
      end
      def heads(context) = model.where(scope_key: B.scope(context))
      def read_revision(row, context)
        return nil if row.revision.zero?
        @journal.read(kind: "memory", key: key("revision", row.topic_key, row.revision), context: context) || raise(K::IntegrityError, "missing memory revision")
      end
      def write_revision(row, item, context)
        data = B.data(item.merge("revision" => row.revision + 1, "updated_at" => now.iso8601(6)))
        @journal.append(kind: "memory", key: key("revision", row.topic_key, data.fetch("revision")), payload: data, context: context)
        row.update!(revision: data.fetch("revision"))
        data
      end

      def validate!(request)
        sources, claims = request.values_at("sources", "claims")
        unless sources.is_a?(Array) && sources.size.between?(1, 32) && claims.is_a?(Array) && claims.size.between?(1, 32)
          raise K::InvalidContract, "bounded nonempty sources and claims required"
        end
        sources.each do |source|
          K::Snapshot.exact_keys!(source, %w[id reference version digest kind max_age_seconds])
          identifier(source["id"])
          %w[reference version].each { |f| bounded_text(source[f]) }
          unless source["digest"].is_a?(String) && /\A[0-9a-f]{64}\z/.match?(source["digest"]) && SOURCE_KINDS.include?(source["kind"]) && source["max_age_seconds"].is_a?(Integer) && source["max_age_seconds"].between?(1, 31_536_000)
            raise K::InvalidContract, "invalid evidence source contract"
          end
        end
        ids = sources.map { |s| s.fetch("id") }
        raise K::InvalidContract, "duplicate source IDs" unless ids.uniq == ids
        claims.each do |claim|
          K::Snapshot.exact_keys!(claim, %w[text kind evidence])
          bounded_text(claim["text"])
          unless %w[assertion reported hypothesis].include?(claim["kind"]) && claim["evidence"].is_a?(Array) && claim["evidence"].size.between?(1, 16)
            raise K::InvalidContract, "typed claim and bounded evidence required"
          end
          claim["evidence"].each do |ref|
            K::Snapshot.exact_keys!(ref, %w[source_id quote])
            bounded_text(ref["quote"])
            raise K::InvalidContract, "unresolved source" unless ids.include?(ref["source_id"])
          end
          kinds = claim["evidence"].map { |r| sources.find { |s| s["id"] == r["source_id"] }.fetch("kind") }
          if claim["kind"] == "assertion" && (kinds - %w[user_statement model_output]).empty?
            raise K::InvalidContract, "statements alone cannot establish an assertion"
          end
        end
        raise K::InvalidContract, "candidate exceeds 256 KiB" if JSON.generate(request).bytesize > 262_144
      end

      def load_sources(sources, context)
        sources.to_h do |source|
          response = B.data(@loader.call(source, context))
          raise K::AccessDenied, "memory source scope mismatch" unless response.is_a?(Hash) && response["scope"] == B.scope(context)
          K::Snapshot.exact_keys!(response, %w[scope reference version kind content observed_at])
          unless response["content"].is_a?(String) && response["content"].bytesize <= 65_536 &&
                 %w[reference version kind].all? { |field| response[field] == source[field] } && K.digest(response["content"]) == source["digest"]
            raise K::IntegrityError, "source changed or exceeds size limit"
          end
          at = K.timestamp(response["observed_at"])
          raise K::IntegrityError, "source observation expired or future" unless Time.iso8601(at) <= now && Time.iso8601(at) + source["max_age_seconds"] >= now
          [source.fetch("id"), response.merge("observed_at" => at)]
        end
      end

      def dependency_reasons(item, context)
        reasons = []
        reasons << "memory_expired" if Time.iso8601(item.fetch("expires_at")) <= now
        reasons << "verifier_version_changed" unless item.fetch("verifier_version") == @verifier_version
        begin
          load_sources(item.fetch("sources"), context)
        rescue K::AccessDenied
          raise
        rescue StandardError => error
          reasons << "source_revalidation_failed:#{error.class.name}"
        end
        reasons
      end
    end
  end
end
