# frozen_string_literal: true

module Agentkit
  module HITL
    # Persistence for suggestions and decisions.
    #
    # The default Hash store is fine for the pure-Ruby core and for specs, but a
    # Rails app needs the real thing: with an in-process store, restarting the
    # server drops every pending approval on the floor, and two web workers
    # disagree about what is pending.
    module Stores
      # Default store. A plain Hash almost works, but the id has to be assigned
      # by whoever persists — the database does it in production, so the
      # in-memory store owns the sequence here.
      class InMemory
        def initialize
          @rows = {}
          @seq  = 0
          @mutex = Mutex.new
        end

        def [](id)        = @mutex.synchronize { @rows[id] }

        def []=(id, row)
          @mutex.synchronize { @rows[id] = row }
        end

        def values        = @mutex.synchronize { @rows.values.dup }
        def key?(id)      = @mutex.synchronize { @rows.key?(id) }

        def insert(suggestion)
          insert_idempotent(suggestion).first
        end

        def insert_idempotent(suggestion)
          @mutex.synchronize do
            if suggestion.idempotency_key
              existing = @rows.values.find do |row|
                row.tenant_key.to_s == suggestion.tenant_key.to_s &&
                  row.operation_namespace.to_s == suggestion.operation_namespace.to_s &&
                  row.idempotency_key.to_s == suggestion.idempotency_key.to_s
              end
              return [resolve_duplicate(existing, suggestion), false] if existing
            end

            suggestion.id ||= (@seq += 1)
            @rows[suggestion.id] = suggestion
            [suggestion, true]
          end
        end

        def transition(id, from:, to:, scope: nil)
          @mutex.synchronize do
            row = @rows[id]
            resolved = Scope.resolve(scope)
            raise SuggestionNotFound, "Suggestion #{id} not found" unless row && resolved.match?(row)
            unless Array(from).map(&:to_s).include?(row.status.to_s)
              raise DecisionConflict,
                    "Suggestion #{id} cannot transition from #{row.status} to #{to}"
            end

            yield(row) if block_given?
            row.status = to.to_s
            @rows[id] = row
            row
          end
        end

        def claim_execution(id, scope: nil)
          transition(id, from: "approved", to: "executing", scope: scope) do |row|
            row.execution_started_at = Time.now
          end
        rescue DecisionConflict, SuggestionNotFound
          nil
        end

        def finish_execution(id, status:, error_code: nil, scope: nil)
          transition(id, from: "executing", to: status, scope: scope) do |row|
            row.execution_error_code = error_code
            row.execution_finished_at = Time.now
          end
        end

        def clear
          @mutex.synchronize do
            @rows = {}
            @seq  = 0
          end
        end

        private

        def resolve_duplicate(existing, candidate)
          known = existing.arguments_digest
          return existing if known.nil? || known == candidate.arguments_digest

          raise IdempotencyConflict,
                "idempotency key already used with different arguments"
        end
      end

      # Maps the Suggestion Struct to and from agentkit_suggestions. Answers the
      # same three messages as a Hash, so HITL does not know the difference.
      class ActiveRecordStore
        COLUMNS = %i[
          suggestion_type title description priority status source_agent payload
          user_id account_id tenant_key idempotency_key prompt_id prompt_version
          model run_id gate_key metadata resolved_at expires_at
          experiment_id experiment_arm operation_namespace arguments_digest
          execution_error_code execution_started_at execution_finished_at
        ].freeze

        def [](id)
          wrap(Agentkit::SuggestionRecord.find_by(id: id))
        end

        # Called on create and after every mutation, so an in-place change to
        # the Struct is written through.
        def []=(id, suggestion)
          row = id && Agentkit::SuggestionRecord.find_by(id: id)
          attrs = attributes_for(suggestion)

          if row
            row.update!(attrs)
          else
            row = Agentkit::SuggestionRecord.create!(attrs)
            suggestion.id = row.id
          end
          suggestion
        end

        def insert(suggestion)
          insert_idempotent(suggestion).first
        end

        def insert_idempotent(suggestion)
          if suggestion.idempotency_key && (existing = idempotency_relation(suggestion).first)
            return [resolve_duplicate(existing, suggestion), false]
          end

          row = nil
          # A savepoint contains a uniqueness race so callers that already run
          # inside a transaction do not leave PostgreSQL in an aborted state.
          Agentkit::SuggestionRecord.transaction(requires_new: true) do
            row = Agentkit::SuggestionRecord.create!(attributes_for(suggestion))
          end
          suggestion.id = row.id
          [suggestion, true]
        rescue ActiveRecord::RecordNotUnique
          existing = idempotency_relation(suggestion).first
          raise unless existing

          [resolve_duplicate(existing, suggestion), false]
        end

        def transition(id, from:, to:, scope: nil)
          Agentkit::SuggestionRecord.transaction do
            row = scoped_relation(scope).lock.find_by(id: id)
            raise SuggestionNotFound, "Suggestion #{id} not found" unless row
            unless Array(from).map(&:to_s).include?(row.status.to_s)
              raise DecisionConflict,
                    "Suggestion #{id} cannot transition from #{row.status} to #{to}"
            end

            suggestion = wrap(row)
            yield(suggestion) if block_given?
            suggestion.status = to.to_s
            row.update!(attributes_for(suggestion))
            wrap(row.reload)
          end
        end

        def claim_execution(id, scope: nil)
          transition(id, from: "approved", to: "executing", scope: scope) do |suggestion|
            suggestion.execution_started_at = Time.now
          end
        rescue DecisionConflict, SuggestionNotFound
          nil
        end

        def finish_execution(id, status:, error_code: nil, scope: nil)
          transition(id, from: "executing", to: status, scope: scope) do |suggestion|
            suggestion.execution_error_code = error_code
            suggestion.execution_finished_at = Time.now
          end
        end

        def values
          Agentkit::SuggestionRecord.order(:id).map { |r| wrap(r) }
        end

        def key?(id) = Agentkit::SuggestionRecord.exists?(id: id)
        def clear    = Agentkit::SuggestionRecord.delete_all

        private

        def attributes_for(suggestion)
          COLUMNS.to_h { |column| [column, suggestion.public_send(column)] }
                 .merge(suggestable: suggestion.suggestable)
        end

        def scoped_relation(scope)
          resolved = Scope.resolve(scope)
          relation = Agentkit::SuggestionRecord.all
          relation = relation.where(tenant_key: resolved.tenant_key) if resolved.tenant_key
          relation = relation.where(account_id: resolved.account_id) if resolved.account_id
          relation
        end

        def idempotency_relation(suggestion)
          Agentkit::SuggestionRecord.where(
            tenant_key: suggestion.tenant_key,
            operation_namespace: suggestion.operation_namespace,
            idempotency_key: suggestion.idempotency_key
          )
        end

        def resolve_duplicate(existing, candidate)
          wrapped = existing.is_a?(Suggestion) ? existing : wrap(existing)
          known = wrapped.arguments_digest
          return wrapped if known.nil? || known == candidate.arguments_digest

          raise IdempotencyConflict,
                "idempotency key already used with different arguments"
        end

        def wrap(row)
          return nil if row.nil?

          Suggestion.new(
            id: row.id, suggestable: row.suggestable, created_at: row.created_at,
            lock_version: row.lock_version,
            **COLUMNS.to_h { |c| [c, row.public_send(c)] }
          )
        end
      end

      # The decision ledger, persisted. Every metric in the base Ledger reads
      # through `entries`, so overriding that plus `record` is enough.
      class ActiveRecordLedger < Ledger
        def record(suggestion, decision:, actor:, mode: "human", rejection_code: nil,
                   rejection_note: nil, final_payload: nil, required: false)
          entry = super

          Agentkit::DecisionRecord.create!(
            suggestion_id: suggestion.id, agent_name: entry.agent_name,
            suggestion_type: entry.suggestion_type, prompt_id: entry.prompt_id,
            prompt_version: entry.prompt_version, model: entry.model,
            decision: entry.decision, actor: entry.actor, mode: entry.mode,
            rejection_code: entry.rejection_code, rejection_note: entry.rejection_note,
            proposed_payload: entry.proposed_payload || {},
            final_payload: entry.final_payload || {},
            edit_distance: entry.edit_distance,
            time_to_decision_s: entry.time_to_decision_s,
            tenant_key: entry.tenant_key,
            experiment_id: entry.experiment_id,
            experiment_arm: entry.experiment_arm
          )
          entry
        rescue StandardError => e
          raise if required

          # Non-decision callers retain the old best-effort behavior.
          Agentkit.logger&.error("[AgentKit::HITL] ledger persistence failed: #{e.message}")
          entry
        end

        def record_outcome(suggestion_id, name:, value: nil)
          row = Agentkit::DecisionRecord.where(suggestion_id: suggestion_id).order(:id).last
          return nil unless row

          row.update!(outcome: name.to_s, outcome_value: value, outcome_at: Time.now)
          to_entry(row)
        end

        def entries(agent: nil, type: nil, since: nil, mode: nil, experiment_id: nil,
                    experiment_arm: nil, prompt_id: nil, tenant_key: nil, scope: nil)
          resolved = Scope.resolve(scope || { tenant_key: tenant_key })
          relation = Agentkit::DecisionRecord.all
          relation = relation.where(tenant_key: resolved.tenant_key) if resolved.tenant_key
          relation = relation.where(agent_name: agent.to_s) if agent
          relation = relation.where(suggestion_type: type.to_s) if type
          relation = relation.where(created_at: since..) if since
          relation = relation.where(mode: mode.to_s) if mode
          relation = relation.where(experiment_id: experiment_id) if experiment_id
          relation = relation.where(experiment_arm: experiment_arm.to_s) if experiment_arm
          relation = relation.where(prompt_id: prompt_id.to_s) if prompt_id
          relation.order(:id).map { |r| to_entry(r) }
        end

        def clear = Agentkit::DecisionRecord.delete_all
        def size  = Agentkit::DecisionRecord.count

        private

        def to_entry(row)
          Entry.new(
            id: row.id, suggestion_id: row.suggestion_id, agent_name: row.agent_name,
            suggestion_type: row.suggestion_type, prompt_id: row.prompt_id,
            prompt_version: row.prompt_version, model: row.model,
            decision: row.decision, actor: row.actor, mode: row.mode,
            rejection_code: row.rejection_code, rejection_note: row.rejection_note,
            proposed_payload: row.proposed_payload, final_payload: row.final_payload,
            edit_distance: row.edit_distance, time_to_decision_s: row.time_to_decision_s,
            outcome: row.outcome, outcome_value: row.outcome_value, outcome_at: row.outcome_at,
            tenant_key: row.tenant_key, created_at: row.created_at,
            experiment_id: row.experiment_id, experiment_arm: row.experiment_arm
          )
        end
      end
    end
  end
end
