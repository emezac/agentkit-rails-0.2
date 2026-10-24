# frozen_string_literal: true

module Agentkit
  module Harness
    # Portable immutable snapshot. Learned procedures are hypotheses for the
    # next task, even after a human activates them for retrieval.
    class Experience
      attr_reader :data

      def initialize(data)
        @data = Harness.deep_freeze(DeclarativeData.normalize(data, label: "experience"))
        freeze
      end

      def id = data.fetch("id")
      def status = data.fetch("status")
      def digest = Harness.digest(data)
      def to_h = data
      def expired?(at: Time.now.utc) = Harness.time(data.fetch("expires_at")) <= at
      def active?(at: Time.now.utc) = status == "active" && !expired?(at: at)
      def content
        "Hypothesis: revalidate against the current task.\n" \
          "Cue: #{data.fetch('cue')}\nLesson: #{data.fetch('lesson')}\n" \
          "Applies to: #{data.fetch('applicability')}\n" \
          "Evidence: #{data.fetch('provenance').fetch('result_digest')}"
      end
    end

    # Uses the existing Memory port for both Ruby and Rails. Append-only
    # snapshots preserve review history. Concurrent conflicting transitions
    # are detected on read and fail closed instead of selecting a winner.
    class ExperienceLibrary
      MEMORY_TYPE = "harness_experience"
      TRANSITIONS = {
        "candidate" => %w[active rejected], "active" => %w[stale superseded rejected],
        "stale" => %w[superseded rejected], "rejected" => [], "superseded" => []
      }.freeze
      attr_reader :domain, :context

      def initialize(domain:, context: Context.resolve)
        @domain = text!(domain, "domain")
        @context = context
        Scope.resolve(context: context)
      end

      # At most one entry per experiment/domain. Only isolated, repeated,
      # successful matched probes may support a durable lesson.
      def capture!(result:, revision_id:, cue:, lesson:, applicability:, topics:,
                   ttl: 90 * 86_400, at: Time.now.utc)
        raise HarnessIntegrityError, "experiment scope mismatch" unless result.scope == scope
        revision = result.revisions.find { |item| item.id == revision_id.to_s }
        contrast = result.contrasts.find { |item| item.revision_id == revision_id.to_s }
        raise HarnessExperimentError, "unknown revision or contrast" unless revision && contrast
        return nil unless eligible?(result, revision, contrast)

        duration = Float(ttl)
        raise ArgumentError, "ttl must be positive and finite" unless duration.finite? && duration.positive?
        id = Harness.digest([scope, domain, result.id])
        existing = find(id)
        if existing
          unless existing.data.fetch("provenance").fetch("result_digest") == result.digest
            raise HarnessIntegrityError, "experiment id reused with different evidence"
          end
          return existing
        end
        entry = Experience.new(
          "schema_version" => 1, "id" => id, "scope" => scope, "domain" => domain,
          "status" => "candidate", "generation" => 1, "parent_digest" => nil,
          "cue" => text!(cue, "cue"), "lesson" => text!(lesson, "lesson"),
          "applicability" => text!(applicability, "applicability"),
          "topics" => Array(topics).map { |item| text!(item, "topic").downcase }.uniq,
          "created_at" => at.utc.iso8601(6), "expires_at" => (at + duration).utc.iso8601(6),
          "confidence" => contrast.attributions.first.confidence,
          "component" => revision.changes.first.target,
          "provenance" => {
            "experiment_id" => result.id, "result_digest" => result.digest,
            "task_digest" => result.task.digest, "base_manifest_digest" => result.base_manifest.digest,
            "revision" => revision.to_h, "contrast" => contrast.to_h,
            "probes" => result.probes.select { |p| p.role == "baseline" || p.revision_id == revision.id }
                             .map { |p| p.to_h.reject { |key, _| %w[observations error].include?(key) } }
          }
        )
        persist!(entry)
      end

      def entries
        rows = Agentkit.with_context(context) { Memory.all(types: [MEMORY_TYPE], ontological: :imagined) }
        snapshots = rows.select do |row|
          row.tenant_key.to_s == context.tenant_key.to_s &&
            row.account_id.to_s == context.to_h[:account_id].to_s && row.metadata["domain"] == domain
        end.map do |row|
          entry = Experience.new(row.metadata.fetch("experience"))
          unless row.metadata["digest"] == entry.digest && entry.data["scope"] == scope && entry.data["domain"] == domain
            raise HarnessIntegrityError, "experience snapshot integrity failure"
          end
          entry
        end
        snapshots.group_by(&:id).values.map do |history|
          versions = history.uniq(&:digest).sort_by { |item| item.data.fetch("generation") }
          versions.each_with_index do |item, index|
            parent = index.zero? ? nil : versions[index - 1].digest
            unless item.data["generation"] == index + 1 && item.data["parent_digest"] == parent
              raise HarnessIntegrityError, "experience history conflict or missing snapshot"
            end
          end
          versions.last
        end.sort_by(&:id).freeze
      end

      def find(id) = entries.find { |item| item.id == id.to_s }

      def transition!(id, to:, actor:, reason:, replacement_id: nil, at: Time.now.utc)
        entry = find(id) || raise(HarnessExperimentError, "experience not found")
        state = to.to_s
        unless TRANSITIONS.fetch(entry.status).include?(state)
          raise HarnessExperimentError, "invalid experience transition #{entry.status} -> #{state}"
        end
        raise HarnessExperimentError, "expired experience cannot be activated" if state == "active" && entry.expired?(at: at)
        if state == "superseded"
          replacement = find(replacement_id)
          unless replacement && replacement.id != entry.id && replacement.active?(at: at)
            raise HarnessExperimentError, "supersession requires another active experience in this library"
          end
        end
        persist!(Experience.new(entry.to_h.merge(
          "status" => state, "generation" => entry.data.fetch("generation") + 1,
          "parent_digest" => entry.digest, "actor" => text!(actor, "actor"),
          "reason" => text!(reason, "reason"), "replacement_id" => replacement_id,
          "updated_at" => at.utc.iso8601(6)
        )))
      end

      # Bounded retrieval delegates relevance and byte limits to ContextMap.
      def retrieve(query:, at: Time.now.utc)
        active = entries.select { |entry| entry.active?(at: at) }
        map = ContextMap.new
        active.each do |entry|
          map.source(entry.id, reference: "experience:#{entry.id}", kind: :hypothesis,
                     topics: entry.data.fetch("topics") + [entry.data.fetch("cue")],
                     digest: Harness.digest(entry.content))
        end
        by_id = active.to_h { |entry| [entry.id, entry] }
        map.compile(query: query, context: context, at: at) { |source| by_id.fetch(source.id).content }
      end

      def maintain!(dry_run: true, at: Time.now.utc)
        stale = entries.select { |entry| entry.status == "active" && entry.expired?(at: at) }
        unless dry_run
          stale.each { |entry| transition!(entry.id, to: :stale, actor: "lifecycle", reason: "validity expired", at: at) }
        end
        { dry_run: dry_run, stale_ids: stale.map(&:id) }
      end

      private

      def scope
        { "tenant_key" => context.tenant_key, "account_id" => context.to_h[:account_id] }
      end

      def eligible?(result, revision, contrast)
        return false unless revision.changes.size == 1 && contrast.attributions.size == 1
        return false unless %w[helped hurt].include?(contrast.attributions.first.verdict)
        return false unless result.validations.any? { |v| v.revision.digest == revision.digest && v.valid? }
        baseline = result.probes.select { |p| p.role == "baseline" }
        candidates = result.probes.select { |p| p.revision_id == revision.id }
        return false unless baseline.size >= 2 && candidates.size == baseline.size
        return false unless baseline.map(&:repetition).uniq.size == baseline.size &&
                            baseline.map(&:repetition).sort == candidates.map(&:repetition).sort
        return false unless (baseline + candidates).all? do |probe|
          probe.successful? && probe.task_digest == result.task.digest &&
            probe.model_digest == result.task.model_digest && probe.environment_digest == result.task.environment_digest &&
            probe.manifest_digest == (probe.role == "baseline" ? result.base_manifest.digest : revision.apply_to(result.base_manifest).digest)
        end
        refs = contrast.attributions.first.evidence_refs
        baseline.any? { |p| (p.evidence_refs & refs).any? } && candidates.any? { |p| (p.evidence_refs & refs).any? }
      end

      def persist!(entry)
        raise HarnessPersistenceError, "experience exceeds checkpoint byte limit" if JSON.generate(entry.to_h).bytesize > context.config.harness.max_checkpoint_bytes
        Agentkit.with_context(context) do
          row = Memory.store(
            "Harness experience #{entry.id} generation #{entry.data.fetch('generation')}",
            type: MEMORY_TYPE, source_agent: "Agentkit::Harness::ExperienceLibrary",
            embed: false, retention: :durable, ontological_type: :imagined,
            metadata: { "domain" => domain, "experience" => entry.to_h, "digest" => entry.digest }, context: context
          )
          raise HarnessPersistenceError, "memory writes disabled" unless row
          Audit.record(event_type: "harness.experience.#{entry.status}", context: context,
                       payload: { experience_id: entry.id, digest: entry.digest, domain: domain })
          Telemetry.emit("harness.experience.transition", dims: { domain: domain, status: entry.status },
                         measures: { generation: entry.data.fetch("generation") })
        end
        entry
      end

      def text!(value, label)
        text = value.to_s.strip
        raise ArgumentError, "#{label} must contain 1..4096 bytes" if text.empty? || text.bytesize > 4096
        text
      end
    end
  end
end
