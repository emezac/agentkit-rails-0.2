# frozen_string_literal: true

module Agentkit
  # Versioned prompt registry with deterministic canary rollout.
  #
  # `astra` built exactly this as domain code (AgentPromptVersion + a bucket by
  # company.id + a hardcoded exclusion for refunds and cancellations). Without
  # it in the kernel, the factory has nothing to experiment on: prompts written
  # as heredocs inside agents cannot be versioned, compared or rolled back.
  #
  #   Agentkit::Prompt.define(:sales_operator, version: 3) do |ctx|
  #     "You are a sales operator for #{ctx.account.name}..."
  #   end
  #
  #   Agentkit::Prompt.canary(:sales_operator, version: 4, percent: 10,
  #                           bucket: ->(ctx) { ctx.account&.id },
  #                           exclude_if: ->(text) { text.match?(/refund/i) })
  module Prompt
    Version = Struct.new(:id, :version, :body, :status, :metadata, keyword_init: true) do
      def render(ctx = nil)
        body.respond_to?(:call) ? body.call(ctx) : body.to_s
      end
    end

    Canary = Struct.new(:id, :version, :percent, :bucket, :exclude_if, :started_at,
                        :experiment_id, keyword_init: true)

    class << self
      def registry  = @registry ||= Hash.new { |h, k| h[k] = {} }
      def canaries  = @canaries ||= {}
      def actives   = @actives ||= {}

      def define(id, version: 1, status: :active, **metadata, &block)
        id = id.to_sym
        body = block || metadata.delete(:body)
        raise ConfigurationError, "Prompt #{id} needs a body or a block" if body.nil?

        registry[id][version] = Version.new(id: id, version: version, body: body,
                                            status: status, metadata: metadata)
        actives[id] = version if status == :active && (actives[id].nil? || version > actives[id])
        registry[id][version]
      end

      def canary(id, version:, percent:, bucket: nil, exclude_if: nil, experiment_id: nil)
        id = id.to_sym
        raise ConfigurationError, "Prompt #{id} v#{version} is not defined" unless registry[id][version]

        canaries[id] = Canary.new(id: id, version: version, percent: percent.to_f,
                                  bucket: bucket, exclude_if: exclude_if, started_at: Time.now,
                                  experiment_id: experiment_id)
      end

      def stop_canary(id) = canaries.delete(id.to_sym)

      # Promote the canary to active. Called by the factory when an experiment
      # meets its promotion criteria — or by a human, one click.
      def promote(id, version: nil)
        id = id.to_sym
        version ||= canaries[id]&.version
        raise ConfigurationError, "Nothing to promote for #{id}" if version.nil?

        actives[id] = version
        canaries.delete(id)
        Telemetry.emit("prompt.promoted", dims: { prompt_id: id, version: version })
        version
      end

      def rollback(id, to:)
        id = id.to_sym
        actives[id] = to
        canaries.delete(id)
        Telemetry.emit("prompt.rolled_back", dims: { prompt_id: id, version: to })
        to
      end

      # Resolve the prompt text for this context, applying canary assignment.
      #
      # @return [Array(String, Integer)] rendered body and the version used, so
      #   the caller can tag telemetry and the decision ledger with it.
      def render(id, ctx = nil)
        id = id.to_sym
        versions = registry[id]
        raise ConfigurationError, "Unknown prompt #{id}" if versions.empty?

        version = assigned_version(id, ctx)
        text    = versions.fetch(version).render(ctx)

        if (canary = effective_canary(id)) && canary.exclude_if&.call(text)
          version = effective_active_version(id)
          text    = versions.fetch(version).render(ctx)
        end
        [text, version]
      end

      def defined?(id) = registry.key?(id.to_sym) && !registry[id.to_sym].empty?
      def versions(id) = registry[id.to_sym].keys.sort
      def active_version(id) = effective_active_version(id.to_sym)

      # Correlates the prompt assignment with the factory experiment that
      # produced it. Callers record both control and variant decisions under
      # one experiment id, avoiding the old global "version 1 vs version 2"
      # comparison that mixed unrelated prompts and tenants.
      def experiment_assignment(id, version:, ctx: nil)
        id = id.to_sym
        canary = effective_canary(id)
        return {} if canary.nil? || canary.experiment_id.nil?

        assigned = assigned_version(id, ctx)
        return {} unless assigned.to_s == version.to_s

        { experiment_id: canary.experiment_id,
          experiment_arm: assigned.to_s == canary.version.to_s ? "variant" : "control" }
      end

      def reset!
        @registry = nil
        @canaries = nil
        @actives  = nil
        self
      end

      private

      # Deterministic bucketing: the same tenant always lands in the same arm,
      # so a canary cannot show a user two different behaviours in one session.
      def assigned_version(id, ctx)
        active = effective_active_version(id) || registry[id].keys.max
        canary = effective_canary(id)
        return active if canary.nil? || canary.percent <= 0

        key =
          if canary.bucket.respond_to?(:call)
            canary.bucket.call(ctx)
          else
            bucket_value(ctx, canary.bucket)
          end
        key ||= ctx&.tenant_key || ctx&.run_id
        return active if key.nil?

        bucket = Digest::MD5.hexdigest("#{id}:#{key}")[0, 8].to_i(16) % 100
        bucket < canary.percent ? canary.version : active
      end

      # Prompt rollout state must survive process boundaries. A diagnosis job
      # normally starts the experiment in a worker, while prompt rendering
      # happens in web processes that never saw the in-memory `canary` call.
      # The experiment row is therefore the source of truth; the local registry
      # remains the fast path for pure-Ruby/non-Rails hosts.
      def effective_canary(id)
        canaries[id] || persisted_canary(id)
      end

      def effective_active_version(id)
        persisted_adoption(id)&.variant || actives[id]
      end

      def persisted_canary(id)
        row = persisted_experiment(id, status: "running")
        return nil unless row

        Canary.new(
          id: id, version: row.variant, percent: row.traffic_pct,
          bucket: row.bucket_by&.to_sym, exclude_if: nil,
          started_at: row.started_at, experiment_id: row.id.to_s
        )
      end

      def persisted_adoption(id)
        persisted_experiment(id, status: "adopted")
      end

      def persisted_experiment(id, status:)
        return nil unless Agentkit.const_defined?(:ExperimentRecord, false) ||
                          Agentkit.autoload?(:ExperimentRecord)

        record = Agentkit.const_get(:ExperimentRecord)
        return nil unless record.table_exists?

        record.where(level: "n2", target: "prompt:#{id}", status: status)
              .order(started_at: :desc, id: :desc).first
      rescue StandardError => e
        Agentkit.logger&.warn("[AgentKit::Prompt] persisted rollout unavailable: #{e.class}: #{e.message}")
        nil
      end

      def bucket_value(ctx, bucket_by)
        case bucket_by&.to_sym
        when :account then ctx&.account.respond_to?(:id) ? ctx.account.id : ctx&.tenant_key
        when :user    then ctx&.user.respond_to?(:id) ? ctx.user.id : ctx&.user
        when :run     then ctx&.run_id
        else ctx&.tenant_key
        end
      end
    end
  end
end
