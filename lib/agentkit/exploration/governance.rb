# frozen_string_literal: true

require "securerandom"

module Agentkit
  module Exploration
    # Durable promotion governance for statistically supported recommendations.
    # A review changes only the declarative binding selected by the host. It can
    # never register code, replace a callable, or mutate a policy registry.
    module Governance
      STATUS = %w[pending approved rejected rolled_back].freeze
      AccountReference = Struct.new(:id)

      Review = Struct.new(
        :id, :target, :status, :tenant_key, :account_id,
        :incumbent_name, :incumbent_version, :incumbent_digest,
        :candidate_name, :candidate_version, :candidate_digest,
        :evidence_digest, :evidence, :submitted_at, :decided_at,
        :reviewed_by, :review_reason, :previous_binding,
        keyword_init: true
      ) do
        def pending? = status == "pending"
        def approved? = status == "approved"
        def rejected? = status == "rejected"
        def rolled_back? = status == "rolled_back"
        def to_h = members.to_h { |member| [member, public_send(member)] }
      end

      Binding = Struct.new(
        :target, :tenant_key, :account_id, :policy_name, :policy_version,
        :policy_digest, :review_id, :generation, :applied_at,
        keyword_init: true
      ) do
        def to_h = members.to_h { |member| [member, public_send(member)] }
      end

      module Stores
        class Memory
          def initialize
            @reviews = {}
            @bindings = {}
            @mutex = Mutex.new
          end

          def submit(review)
            @mutex.synchronize do
              existing = @reviews.values.find do |candidate|
                same_scope?(candidate, review) && candidate.target == review.target &&
                  candidate.evidence_digest == review.evidence_digest
              end
              return copy(existing) if existing

              yield(review) if block_given?
              @reviews[review.id] = copy(review)
              copy(review)
            end
          end

          def all(scope:, status: nil, limit: 100)
            @mutex.synchronize do
              @reviews.values.select do |review|
                scope.match?(review) && (status.nil? || review.status == status.to_s)
              end.sort_by(&:submitted_at).last(limit).reverse.map { |review| copy(review) }
            end
          end

          def find(id, scope:)
            @mutex.synchronize do
              review = @reviews[id.to_s]
              review && scope.match?(review) ? copy(review) : nil
            end
          end

          def binding(target, scope:)
            @mutex.synchronize { copy(@bindings[binding_key(target, scope)]) }
          end

          def bindings(scope:)
            @mutex.synchronize do
              @bindings.values.select { |binding| scope.match?(binding) }
                       .sort_by(&:target).map { |binding| copy(binding) }
            end
          end

          def approve(id, actor:, reason:, scope:)
            @mutex.synchronize do
              current = owned_review!(id, scope)
              transitionable!(current, "pending")
              key = binding_key(current.target, scope)
              previous = descriptor(@bindings[key])
              now = Time.now.utc
              review = replace(current, status: "approved", reviewed_by: actor,
                                review_reason: reason, decided_at: now,
                                previous_binding: previous)
              binding = Binding.new(
                target: current.target, tenant_key: current.tenant_key,
                account_id: current.account_id, policy_name: current.candidate_name,
                policy_version: current.candidate_version,
                policy_digest: current.candidate_digest, review_id: current.id,
                generation: (@bindings[key]&.generation || 0) + 1, applied_at: now
              ).freeze
              yield(review, binding) if block_given?
              @reviews[id.to_s] = review
              @bindings[key] = binding
              copy(review)
            end
          end

          def reject(id, actor:, reason:, scope:)
            @mutex.synchronize do
              current = owned_review!(id, scope)
              transitionable!(current, "pending")
              review = replace(current, status: "rejected", reviewed_by: actor,
                                review_reason: reason, decided_at: Time.now.utc)
              yield(review, nil) if block_given?
              @reviews[id.to_s] = review
              copy(review)
            end
          end

          def rollback(id, actor:, reason:, scope:)
            @mutex.synchronize do
              current = owned_review!(id, scope)
              transitionable!(current, "approved")
              key = binding_key(current.target, scope)
              active = @bindings[key]
              unless active&.review_id == current.id
                raise DecisionConflict, "only the active exploration binding can be rolled back"
              end

              review = replace(current, status: "rolled_back", reviewed_by: actor,
                                review_reason: reason, decided_at: Time.now.utc)
              restored = binding_from(current.previous_binding, current, active.generation + 1)
              yield(review, restored) if block_given?
              @reviews[id.to_s] = review
              restored ? @bindings[key] = restored : @bindings.delete(key)
              copy(review)
            end
          end

          private

          def owned_review!(id, scope)
            review = @reviews[id.to_s]
            raise ConfigurationError, "exploration review not found" unless review && scope.match?(review)

            review
          end

          def transitionable!(review, expected)
            return if review.status == expected

            raise DecisionConflict, "exploration review is already #{review.status}"
          end

          def binding_key(target, scope)
            [scope.tenant_key || "__global__", scope.account_id || 0, target.to_s]
          end

          def same_scope?(left, right)
            left.tenant_key.to_s == right.tenant_key.to_s &&
              left.account_id.to_i == right.account_id.to_i
          end

          def descriptor(binding)
            binding && binding.to_h.transform_keys(&:to_s)
          end

          def binding_from(value, review, generation)
            data = value || {}
            return if data.empty?

            Binding.new(
              target: review.target, tenant_key: review.tenant_key,
              account_id: review.account_id, policy_name: data["policy_name"],
              policy_version: data["policy_version"], policy_digest: data["policy_digest"],
              review_id: data["review_id"], generation: generation,
              applied_at: Time.now.utc
            ).freeze
          end

          def replace(review, **attrs)
            Review.new(**review.to_h.merge(attrs)).freeze
          end

          def copy(value)
            value && Marshal.load(Marshal.dump(value))
          end
        end

        class ActiveRecord
          def submit(review)
            row = Agentkit::ExplorationReviewRecord.find_by(
              tenant_key: review.tenant_key, account_id: account_key(review.account_id),
              target: review.target, evidence_digest: review.evidence_digest
            )
            return wrap_review(row) if row

            Agentkit::ExplorationReviewRecord.transaction do
              row = Agentkit::ExplorationReviewRecord.create!(review_attributes(review))
              yield(wrap_review(row)) if block_given?
              wrap_review(row)
            end
          rescue ::ActiveRecord::RecordNotUnique
            retry
          end

          def all(scope:, status: nil, limit: 100)
            relation = scoped_reviews(scope)
            relation = relation.where(status: status.to_s) if status
            relation.order(submitted_at: :desc).limit(limit).map { |row| wrap_review(row) }
          end

          def find(id, scope:)
            row = scoped_reviews(scope).find_by(dossier_id: id.to_s)
            row && wrap_review(row)
          end

          def binding(target, scope:)
            row = scoped_bindings(scope).find_by(target: target.to_s)
            row && wrap_binding(row)
          end

          def bindings(scope:)
            scoped_bindings(scope).order(:target).map { |row| wrap_binding(row) }
          end

          def approve(id, actor:, reason:, scope:)
            transition(id, from: "pending", to: "approved", actor: actor,
                       reason: reason, scope: scope) do |review_row|
              binding = scoped_bindings(scope).lock.find_or_initialize_by(target: review_row.target)
              previous = binding.persisted? ? binding_descriptor(binding) : {}
              now = Time.now.utc
              review_row.update!(reviewed_by: actor, review_reason: reason,
                                 decided_at: now, previous_binding: previous)
              binding.assign_attributes(
                tenant_key: review_row.tenant_key, account_id: review_row.account_id,
                policy_name: review_row.candidate_name,
                policy_version: review_row.candidate_version,
                policy_digest: review_row.candidate_digest,
                dossier_id: review_row.dossier_id,
                generation: binding.generation.to_i + 1, applied_at: now
              )
              binding.save!
              yield(wrap_review(review_row), wrap_binding(binding)) if block_given?
            end
          rescue ::ActiveRecord::RecordNotUnique
            retry
          end

          def reject(id, actor:, reason:, scope:)
            transition(id, from: "pending", to: "rejected", actor: actor,
                       reason: reason, scope: scope) do |review_row|
              review_row.update!(reviewed_by: actor, review_reason: reason,
                                 decided_at: Time.now.utc)
              yield(wrap_review(review_row), nil) if block_given?
            end
          end

          def rollback(id, actor:, reason:, scope:)
            transition(id, from: "approved", to: "rolled_back", actor: actor,
                       reason: reason, scope: scope) do |review_row|
              binding = scoped_bindings(scope).lock.find_by(target: review_row.target)
              unless binding&.dossier_id == review_row.dossier_id
                raise DecisionConflict, "only the active exploration binding can be rolled back"
              end

              review_row.update!(reviewed_by: actor, review_reason: reason,
                                 decided_at: Time.now.utc)
              restored = restore_binding(binding, review_row.previous_binding)
              yield(wrap_review(review_row), restored && wrap_binding(restored)) if block_given?
            end
          end

          private

          def transition(id, from:, to:, actor:, reason:, scope:)
            Agentkit::ExplorationReviewRecord.transaction do
              row = scoped_reviews(scope).lock.find_by(dossier_id: id.to_s)
              raise ConfigurationError, "exploration review not found" unless row
              raise DecisionConflict, "exploration review is already #{row.status}" unless row.status == from

              row.status = to
              yield(row)
              wrap_review(row.reload)
            end
          end

          def restore_binding(binding, previous)
            data = previous.to_h
            if data.empty?
              binding.destroy!
              return nil
            end
            binding.update!(policy_name: data.fetch("policy_name"),
                            policy_version: data.fetch("policy_version"),
                            policy_digest: data.fetch("policy_digest"),
                            dossier_id: data.fetch("review_id"),
                            generation: binding.generation.to_i + 1,
                            applied_at: Time.now.utc)
            binding
          end

          def scoped_reviews(scope)
            Agentkit::ExplorationReviewRecord.where(
              tenant_key: scope.tenant_key || "__global__", account_id: account_key(scope.account_id)
            )
          end

          def scoped_bindings(scope)
            Agentkit::ExplorationPolicyBindingRecord.where(
              tenant_key: scope.tenant_key || "__global__", account_id: account_key(scope.account_id)
            )
          end

          def account_key(value) = value || 0

          def review_attributes(review)
            review.to_h.slice(
              :target, :status, :tenant_key, :incumbent_name, :incumbent_version,
              :incumbent_digest, :candidate_name, :candidate_version,
              :candidate_digest, :evidence_digest, :evidence, :submitted_at
            ).merge(dossier_id: review.id, account_id: account_key(review.account_id))
          end

          def wrap_review(row)
            Review.new(
              id: row.dossier_id, target: row.target, status: row.status,
              tenant_key: row.tenant_key, account_id: row.account_id.zero? ? nil : row.account_id,
              incumbent_name: row.incumbent_name, incumbent_version: row.incumbent_version,
              incumbent_digest: row.incumbent_digest, candidate_name: row.candidate_name,
              candidate_version: row.candidate_version, candidate_digest: row.candidate_digest,
              evidence_digest: row.evidence_digest, evidence: row.evidence,
              submitted_at: row.submitted_at, decided_at: row.decided_at,
              reviewed_by: row.reviewed_by, review_reason: row.review_reason,
              previous_binding: row.previous_binding
            ).freeze
          end

          def wrap_binding(row)
            Binding.new(
              target: row.target, tenant_key: row.tenant_key,
              account_id: row.account_id.zero? ? nil : row.account_id,
              policy_name: row.policy_name, policy_version: row.policy_version,
              policy_digest: row.policy_digest, review_id: row.dossier_id,
              generation: row.generation, applied_at: row.applied_at
            ).freeze
          end

          def binding_descriptor(binding)
            wrap_binding(binding).to_h.transform_keys(&:to_s)
          end
        end
      end

      class << self
        attr_writer :store

        def store
          return @store if @store
          return @store = Stores::Memory.new if Agentkit.config.exploration.store.to_sym == :memory
          return @store = Stores::ActiveRecord.new if active_record_available?

          @store = Stores::Memory.new
        end

        def reset!
          @store = nil
          self
        end

        def submit!(target:, recommendation:, scope: nil)
          resolved_scope = Scope.resolve(scope)
          validate_recommendation!(recommendation)
          incumbent, candidate = recommendation.holdout_evaluations
          evidence = evidence_for(recommendation)
          review = Review.new(
            id: SecureRandom.uuid, target: normalize_target(target), status: "pending",
            tenant_key: resolved_scope.tenant_key || "__global__",
            account_id: resolved_scope.account_id,
            incumbent_name: incumbent.policy_name, incumbent_version: incumbent.policy_version,
            incumbent_digest: incumbent.policy_digest,
            candidate_name: candidate.policy_name, candidate_version: candidate.policy_version,
            candidate_digest: candidate.policy_digest,
            evidence_digest: Exploration.digest_for(evidence), evidence: evidence,
            submitted_at: Time.now.utc, previous_binding: {}
          ).freeze
          store.submit(review) do |persisted|
            audit!("submitted", persisted, scope: resolved_scope)
          end.tap { emit("submitted") }
        end

        def approve!(review, actor:, reason: nil, scope: nil)
          transition(:approve, review, actor: actor, reason: reason, scope: scope)
        end

        def reject!(review, actor:, reason:, scope: nil)
          transition(:reject, review, actor: actor, reason: required_reason(reason), scope: scope)
        end

        def rollback!(review, actor:, reason:, scope: nil)
          transition(:rollback, review, actor: actor, reason: required_reason(reason), scope: scope)
        end

        def reviews(scope: nil, status: nil, limit: 100)
          maximum = [[Integer(limit), 1].max, 200].min
          store.all(scope: Scope.resolve(scope), status: status, limit: maximum)
        rescue ArgumentError, TypeError
          raise ConfigurationError, "exploration review limit must be an integer"
        end

        def find(id, scope: nil)
          store.find(id, scope: Scope.resolve(scope))
        end

        def binding(target, scope: nil)
          store.binding(normalize_target(target), scope: Scope.resolve(scope))
        end

        def bindings(scope: nil)
          store.bindings(scope: Scope.resolve(scope))
        end

        private

        def transition(operation, review, actor:, reason:, scope:)
          principal = actor.to_s.strip
          raise ConfigurationError, "exploration review actor is required" if principal.empty?

          resolved_scope = Scope.resolve(scope)
          id = review.respond_to?(:id) ? review.id : review
          event = { approve: "approved", reject: "rejected", rollback: "rolled_back" }.fetch(operation)
          store.public_send(operation, id, actor: principal, reason: reason.to_s.strip,
                            scope: resolved_scope) do |persisted, binding|
            audit!(event, persisted, binding: binding, scope: resolved_scope)
          end.tap { emit(event) }
        end

        def validate_recommendation!(recommendation)
          unless recommendation.respond_to?(:status) && recommendation.status == "recommend_review" &&
                 recommendation.requires_review && !recommendation.auto_promoted &&
                 recommendation.reason == "statistically_significant_holdout_improvement" &&
                 recommendation.comparison&.significant &&
                 Array(recommendation.holdout_evaluations).size == 2
            raise ConfigurationError,
                  "only a significant holdout recommendation can enter exploration review"
          end
          incumbent, candidate = recommendation.holdout_evaluations
          if incumbent.policy_digest == candidate.policy_digest
            raise ConfigurationError, "exploration review candidate must differ from the incumbent"
          end
          unless recommendation.incumbent == incumbent.policy_name &&
                 recommendation.selected == candidate.policy_name
            raise ConfigurationError, "exploration review recommendation does not match its holdout evidence"
          end
        end

        def evidence_for(recommendation)
          {
            "schema_version" => 1,
            "status" => recommendation.status,
            "level" => recommendation.level,
            "reason" => recommendation.reason,
            "incumbent" => recommendation.incumbent,
            "selected" => recommendation.selected,
            "training" => Array(recommendation.evaluations).map { |item| evaluation_summary(item) },
            "holdout_evaluations" => Array(recommendation.holdout_evaluations).map do |item|
              evaluation_summary(item)
            end,
            "pareto_frontier" => recommendation.pareto_frontier,
            "holdout" => recommendation.holdout,
            "comparison" => recommendation.comparison.to_h
          }
        end

        def evaluation_summary(item)
          item.to_h.reject { |key, _| key.to_sym == :replays }.transform_keys(&:to_s)
        end

        def normalize_target(value)
          target = value.to_s.strip
          unless target.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.:\/-]{0,199}\z/)
            raise ConfigurationError, "exploration review target is invalid"
          end
          target
        end

        def required_reason(value)
          reason = value.to_s.strip
          raise ConfigurationError, "exploration review reason is required" if reason.empty?

          reason
        end

        def audit!(event, review, binding: nil, scope:)
          current = Context.current
          current_account_id = current&.account&.respond_to?(:id) ? current.account.id : current&.account
          context = if current && current.tenant_key.to_s == scope.tenant_key.to_s &&
                       current_account_id.to_s == scope.account_id.to_s
                      current
                    else
                      account = scope.account_id && AccountReference.new(scope.account_id)
                      Context.new(account: account, tenant_key: scope.tenant_key,
                                  principal: scope.principal)
                    end
          Audit.record(
            event_type: "exploration.review.#{event}", status: review.status,
            payload: {
              review_id: review.id, target: review.target,
              incumbent_digest: review.incumbent_digest,
              candidate_digest: review.candidate_digest,
              evidence_digest: review.evidence_digest,
              reviewed_by: review.reviewed_by, reason: review.review_reason,
              active_binding_digest: binding&.policy_digest,
              binding_generation: binding&.generation
            }.compact,
            context: context, failure_mode: :required
          )
        end

        def emit(status)
          Telemetry.emit("exploration.review.transition",
                         dims: { status: status }, measures: { count: 1 })
        end

        def active_record_available?
          defined?(Agentkit::ExplorationReviewRecord) &&
            Agentkit::ExplorationReviewRecord.table_exists? &&
            Agentkit::ExplorationPolicyBindingRecord.table_exists?
        rescue StandardError
          false
        end
      end
    end

    class << self
      def submit_recommendation!(target:, recommendation:, scope: nil)
        Governance.submit!(target: target, recommendation: recommendation, scope: scope)
      end

      def approve_recommendation!(review, actor:, reason: nil, scope: nil)
        Governance.approve!(review, actor: actor, reason: reason, scope: scope)
      end

      def reject_recommendation!(review, actor:, reason:, scope: nil)
        Governance.reject!(review, actor: actor, reason: reason, scope: scope)
      end

      def rollback_recommendation!(review, actor:, reason:, scope: nil)
        Governance.rollback!(review, actor: actor, reason: reason, scope: scope)
      end

      def reviews(scope: nil, status: nil, limit: 100)
        Governance.reviews(scope: scope, status: status, limit: limit)
      end

      def policy_binding(target:, scope: nil)
        Governance.binding(target, scope: scope)
      end

      def policy_bindings(scope: nil)
        Governance.bindings(scope: scope)
      end
    end
  end
end
