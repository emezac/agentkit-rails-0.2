# frozen_string_literal: true

module Agentkit
  module Actions
    module Stores
      class InMemory
        def initialize
          @proposals = {}
          @decisions = []
          @attempts = []
          @outcomes = []
          @outboxes = []
          @sequences = Hash.new(0)
          @mutex = Mutex.new
        end

        def create_proposal(proposal)
          @mutex.synchronize do
            if proposal.idempotency_key
              existing = @proposals.values.find do |row|
                row.tenant_key == proposal.tenant_key &&
                  row.operation_namespace == proposal.operation_namespace &&
                  row.idempotency_key == proposal.idempotency_key
              end
              if existing
                unless existing.arguments_digest == proposal.arguments_digest &&
                       existing.action_type == proposal.action_type
                  raise IdempotencyConflict, "idempotency key was already used with a different action"
                end
                return [copy(existing), false]
              end
            end
            proposal.id = next_id(:proposal)
            @proposals[proposal.id] = copy(proposal)
            [copy(proposal), true]
          end
        end

        def transition(id, from:, to:)
          @mutex.synchronize do
            proposal = raw_fetch(id)
            raise ActionTransitionConflict, "action is #{proposal.status}, expected #{from}" unless proposal.status == from

            StateMachine.validate!(from, to)
            proposal.status = to
            proposal.updated_at = Time.now
            copy(proposal)
          end
        end

        def decide(id, decision, create_outbox:)
          @mutex.synchronize do
            proposal = raw_fetch(id)
            target = decision.decision == "approved" ? "approved" : "rejected"
            StateMachine.validate!(proposal.status, target)
            raise ActionTransitionConflict, "action already has a decision" if @decisions.any? { |row| row.proposal_id == proposal.id }

            decision.id = next_id(:decision)
            @decisions << copy(decision)
            proposal.status = target
            proposal.updated_at = Time.now
            outbox = create_outbox ? build_outbox(proposal) : nil
            [copy(proposal), copy(outbox)]
          end
        end

        def claim_execution(id, scope:, retry_failed:, retry_unknown:)
          @mutex.synchronize do
            proposal = raw_find(id, scope)
            raise ActionNotFound, "action #{id} not found" unless proposal
            allowed = proposal.status == "approved" ||
                      (proposal.status == "execution_failed" && retry_failed) ||
                      (proposal.status == "execution_unknown" && retry_unknown)
            return [nil, nil] unless allowed

            StateMachine.validate!(proposal.status, "executing")
            proposal.status = "executing"
            proposal.updated_at = Time.now
            number = @attempts.count { |row| row.proposal_id == proposal.id } + 1
            attempt = ExecutionAttempt.new(
              id: next_id(:attempt), proposal_id: proposal.id, tenant_key: proposal.tenant_key,
              attempt_number: number, idempotency_key: execution_key(proposal),
              status: "executing", started_at: Time.now
            )
            @attempts << copy(attempt)
            [copy(proposal), copy(attempt)]
          end
        end

        def finish_execution(proposal_id, attempt_id, status:, canonical_response: nil,
                             error_code: nil, external_result_ref: nil, scope: nil)
          @mutex.synchronize do
            proposal = raw_find(proposal_id, scope)
            raise ActionNotFound, "action #{proposal_id} not found" unless proposal
            StateMachine.validate!(proposal.status, status)
            attempt = @attempts.find { |row| row.id == attempt_id && row.proposal_id == proposal.id }
            raise ActionNotFound, "execution attempt #{attempt_id} not found" unless attempt

            attempt.status = status
            attempt.finished_at = Time.now
            attempt.error_code = error_code
            attempt.external_result_ref = external_result_ref
            attempt.canonical_response = canonical_response
            proposal.status = status
            proposal.canonical_response = canonical_response if canonical_response
            proposal.updated_at = Time.now
            copy(proposal)
          end
        end

        def reconcile(id, to:, external_result_ref: nil, scope: nil)
          @mutex.synchronize do
            proposal = raw_find(id, scope)
            raise ActionNotFound, "action #{id} not found" unless proposal
            StateMachine.validate!(proposal.status, to)
            proposal.status = to
            proposal.updated_at = Time.now
            last = @attempts.reverse.find { |row| row.proposal_id == proposal.id }
            last.external_result_ref = external_result_ref if last
            copy(proposal)
          end
        end

        def add_outcome(outcome)
          @mutex.synchronize do
            outcome.id = next_id(:outcome)
            @outcomes << copy(outcome)
            copy(outcome)
          end
        end

        def find_proposal(id, scope: nil)
          @mutex.synchronize { copy(raw_find(id, scope)) }
        end

        def proposals(scope: nil)
          @mutex.synchronize do
            @proposals.values.select { |row| tenant_match?(row, scope) }.map { |row| copy(row) }
          end
        end

        def decisions(id) = @mutex.synchronize { @decisions.select { |row| row.proposal_id == id }.map { |row| copy(row) } }
        def attempts(id) = @mutex.synchronize { @attempts.select { |row| row.proposal_id == id }.map { |row| copy(row) } }
        def outcomes(id) = @mutex.synchronize { @outcomes.select { |row| row.proposal_id == id }.map { |row| copy(row) } }

        def pending_outboxes(limit:, proposal_id: nil)
          @mutex.synchronize do
            @outboxes.select { |row| row.status == "pending" && (!proposal_id || row.proposal_id == proposal_id) }
                     .first(limit).map { |row| copy(row) }
          end
        end

        def mark_outbox(id, status:, error_code: nil)
          @mutex.synchronize do
            row = @outboxes.find { |candidate| candidate.id == id }
            return unless row

            row.delivery_attempts += 1
            row.status = status
            row.last_error_code = error_code
            row.dispatched_at = Time.now if status == "dispatched"
            copy(row)
          end
        end

        private

        def build_outbox(proposal)
          row = Outbox.new(id: next_id(:outbox), proposal_id: proposal.id,
                           tenant_key: proposal.tenant_key, event_type: "action.execute",
                           status: "pending", delivery_attempts: 0, created_at: Time.now)
          @outboxes << row
          row
        end

        def raw_fetch(id) = raw_find(id, nil) || raise(ActionNotFound, "action #{id} not found")

        def raw_find(id, scope)
          row = @proposals[id.to_i]
          row ||= @proposals.values.find { |candidate| candidate.public_id == id.to_s }
          row if row && tenant_match?(row, scope)
        end

        def tenant_match?(row, scope)
          tenant = scope.respond_to?(:tenant_key) ? scope.tenant_key : scope&.fetch(:tenant_key, nil)
          tenant.nil? || row.tenant_key == tenant
        end

        def execution_key(proposal)
          proposal.idempotency_key.to_s.empty? ? "action:#{proposal.public_id}" : proposal.idempotency_key
        end

        def next_id(kind) = (@sequences[kind] += 1)
        def copy(value) = value && Marshal.load(Marshal.dump(value))
      end

      class ActiveRecord
        def create_proposal(proposal)
          existing = idempotent_match(proposal)
          return validate_idempotent(existing, proposal) if existing

          row = Agentkit::ActionProposalRecord.create!(attributes(proposal, Proposal))
          [wrap_proposal(row), true]
        rescue ::ActiveRecord::RecordNotUnique
          validate_idempotent(idempotent_match(proposal), proposal)
        end

        def transition(id, from:, to:)
          Agentkit::ActionProposalRecord.transaction do
            row = find_row!(id, nil).lock!
            raise ActionTransitionConflict, "action is #{row.status}, expected #{from}" unless row.status == from

            StateMachine.validate!(from, to)
            row.update!(status: to)
            wrap_proposal(row)
          end
        end

        def decide(id, decision, create_outbox:)
          Agentkit::ActionProposalRecord.transaction do
            row = find_row!(id, nil).lock!
            target = decision.decision == "approved" ? "approved" : "rejected"
            StateMachine.validate!(row.status, target)
            Agentkit::ActionDecisionRecord.create!(attributes(decision, Decision))
            row.update!(status: target)
            outbox = if create_outbox
                       Agentkit::ActionOutboxRecord.create!(proposal_id: row.id,
                                                            tenant_key: row.tenant_key,
                                                            event_type: "action.execute",
                                                            status: "pending")
                     end
            [wrap_proposal(row), wrap_outbox(outbox)]
          end
        rescue ::ActiveRecord::RecordNotUnique
          raise ActionTransitionConflict, "action already has a decision"
        end

        def claim_execution(id, scope:, retry_failed:, retry_unknown:)
          Agentkit::ActionProposalRecord.transaction do
            row = find_row!(id, scope).lock!
            allowed = row.status == "approved" ||
                      (row.status == "execution_failed" && retry_failed) ||
                      (row.status == "execution_unknown" && retry_unknown)
            next [nil, nil] unless allowed

            StateMachine.validate!(row.status, "executing")
            number = Agentkit::ExecutionAttemptRecord.where(proposal_id: row.id).maximum(:attempt_number).to_i + 1
            row.update!(status: "executing")
            attempt = Agentkit::ExecutionAttemptRecord.create!(
              proposal_id: row.id, tenant_key: row.tenant_key, attempt_number: number,
              idempotency_key: row.idempotency_key.presence || "action:#{row.public_id}",
              status: "executing", started_at: Time.now
            )
            [wrap_proposal(row), wrap_attempt(attempt)]
          end
        end

        def finish_execution(proposal_id, attempt_id, status:, canonical_response: nil,
                             error_code: nil, external_result_ref: nil, scope: nil)
          Agentkit::ActionProposalRecord.transaction do
            row = find_row!(proposal_id, scope).lock!
            StateMachine.validate!(row.status, status)
            attempt = Agentkit::ExecutionAttemptRecord.lock.find_by!(id: attempt_id, proposal_id: row.id)
            attempt.update!(status: status, finished_at: Time.now, error_code: error_code,
                            external_result_ref: external_result_ref,
                            canonical_response: canonical_response)
            changes = { status: status }
            changes[:canonical_response] = canonical_response if canonical_response
            row.update!(changes)
            wrap_proposal(row)
          end
        end

        def reconcile(id, to:, external_result_ref: nil, scope: nil)
          Agentkit::ActionProposalRecord.transaction do
            row = find_row!(id, scope).lock!
            StateMachine.validate!(row.status, to)
            row.update!(status: to)
            row.execution_attempts.order(attempt_number: :desc).first&.update!(external_result_ref: external_result_ref)
            wrap_proposal(row)
          end
        end

        def add_outcome(outcome)
          wrap_outcome(Agentkit::ActionOutcomeRecord.create!(attributes(outcome, Outcome)))
        end

        def find_proposal(id, scope: nil)
          row = relation(scope).find_by(id: numeric_id(id)) || relation(scope).find_by(public_id: id.to_s)
          wrap_proposal(row)
        end

        def proposals(scope: nil) = relation(scope).order(:created_at).map { |row| wrap_proposal(row) }
        def decisions(id) = Agentkit::ActionDecisionRecord.where(proposal_id: id).order(:decided_at).map { |row| wrap_decision(row) }
        def attempts(id) = Agentkit::ExecutionAttemptRecord.where(proposal_id: id).order(:attempt_number).map { |row| wrap_attempt(row) }
        def outcomes(id) = Agentkit::ActionOutcomeRecord.where(proposal_id: id).order(:observed_at).map { |row| wrap_outcome(row) }

        def pending_outboxes(limit:, proposal_id: nil)
          rows = Agentkit::ActionOutboxRecord.where(status: "pending")
          rows = rows.where(proposal_id: proposal_id) if proposal_id
          rows.order(:created_at).limit(limit).map { |row| wrap_outbox(row) }
        end

        def mark_outbox(id, status:, error_code: nil)
          row = Agentkit::ActionOutboxRecord.find(id)
          row.update!(status: status, delivery_attempts: row.delivery_attempts + 1,
                      last_error_code: error_code,
                      dispatched_at: status == "dispatched" ? Time.now : row.dispatched_at)
          wrap_outbox(row)
        end

        private

        def relation(scope)
          tenant = scope.respond_to?(:tenant_key) ? scope.tenant_key : scope&.fetch(:tenant_key, nil)
          tenant ? Agentkit::ActionProposalRecord.where(tenant_key: tenant) : Agentkit::ActionProposalRecord.all
        end

        def find_row!(id, scope)
          relation(scope).find_by(id: numeric_id(id)) || relation(scope).find_by!(public_id: id.to_s)
        rescue ::ActiveRecord::RecordNotFound
          raise ActionNotFound, "action #{id} not found"
        end

        def numeric_id(value) = value.to_s.match?(/\A\d+\z/) ? value.to_i : -1

        def idempotent_match(proposal)
          return nil unless proposal.idempotency_key

          Agentkit::ActionProposalRecord.find_by(
            tenant_key: proposal.tenant_key, operation_namespace: proposal.operation_namespace,
            idempotency_key: proposal.idempotency_key
          )
        end

        def validate_idempotent(row, proposal)
          unless row && row.arguments_digest == proposal.arguments_digest && row.action_type == proposal.action_type
            raise IdempotencyConflict, "idempotency key was already used with a different action"
          end
          [wrap_proposal(row), false]
        end

        def attributes(value, klass)
          value.to_h.slice(*klass.members).except(:id, :created_at, :updated_at, :lock_version)
        end

        def wrap_proposal(row) = row && Proposal.new(**row.attributes.symbolize_keys.slice(*Proposal.members))
        def wrap_decision(row) = row && Decision.new(**row.attributes.symbolize_keys.slice(*Decision.members))
        def wrap_attempt(row) = row && ExecutionAttempt.new(**row.attributes.symbolize_keys.slice(*ExecutionAttempt.members))
        def wrap_outcome(row) = row && Outcome.new(**row.attributes.symbolize_keys.slice(*Outcome.members))
        def wrap_outbox(row) = row && Outbox.new(**row.attributes.symbolize_keys.slice(*Outbox.members))
      end
    end
  end
end
