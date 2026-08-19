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
        end

        def [](id)        = @rows[id]

        def []=(id, row)
          @rows[id] = row
        end

        def values        = @rows.values
        def key?(id)      = @rows.key?(id)

        def insert(suggestion)
          suggestion.id ||= (@seq += 1)
          @rows[suggestion.id] = suggestion
        end

        def clear
          @rows = {}
          @seq  = 0
        end
      end

      # Maps the Suggestion Struct to and from agentkit_suggestions. Answers the
      # same three messages as a Hash, so HITL does not know the difference.
      class ActiveRecordStore
        COLUMNS = %i[
          suggestion_type title description priority status source_agent payload
          user_id account_id tenant_key idempotency_key prompt_id prompt_version
          model run_id gate_key metadata resolved_at expires_at
          experiment_id experiment_arm
        ].freeze

        def [](id)
          wrap(Agentkit::SuggestionRecord.find_by(id: id))
        end

        # Called on create and after every mutation, so an in-place change to
        # the Struct is written through.
        def []=(id, suggestion)
          row = id && Agentkit::SuggestionRecord.find_by(id: id)
          attrs = COLUMNS.to_h { |c| [c, suggestion.public_send(c)] }
                         .merge(suggestable: suggestion.suggestable)

          if row
            row.update!(attrs)
          else
            row = Agentkit::SuggestionRecord.create!(attrs)
            suggestion.id = row.id
          end
          suggestion
        end

        def insert(suggestion)
          self[nil] = suggestion
        end

        def values
          Agentkit::SuggestionRecord.order(:id).map { |r| wrap(r) }
        end

        def key?(id) = Agentkit::SuggestionRecord.exists?(id: id)
        def clear    = Agentkit::SuggestionRecord.delete_all

        private

        def wrap(row)
          return nil if row.nil?

          Suggestion.new(
            id: row.id, suggestable: row.suggestable, created_at: row.created_at,
            **COLUMNS.to_h { |c| [c, row.public_send(c)] }
          )
        end
      end

      # The decision ledger, persisted. Every metric in the base Ledger reads
      # through `entries`, so overriding that plus `record` is enough.
      class ActiveRecordLedger < Ledger
        def record(suggestion, decision:, actor:, mode: "human", rejection_code: nil,
                   rejection_note: nil, final_payload: nil)
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
          # A ledger write must not break the approval it is recording.
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
                    experiment_arm: nil, prompt_id: nil, tenant_key: nil)
          scope = Agentkit::DecisionRecord.all
          scope = scope.where(agent_name: agent.to_s) if agent
          scope = scope.where(suggestion_type: type.to_s) if type
          scope = scope.where(created_at: since..) if since
          scope = scope.where(mode: mode.to_s) if mode
          scope = scope.where(experiment_id: experiment_id) if experiment_id
          scope = scope.where(experiment_arm: experiment_arm.to_s) if experiment_arm
          scope = scope.where(prompt_id: prompt_id.to_s) if prompt_id
          scope = scope.where(tenant_key: tenant_key.to_s) if tenant_key
          scope.order(:id).map { |r| to_entry(r) }
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
