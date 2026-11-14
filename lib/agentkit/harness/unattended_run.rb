# frozen_string_literal: true

module Agentkit
  module Harness
    # Durable coordination, NOT an executor or sandbox. A trusted host launches
    # isolated jobs and independently records observations through these ports.
    class UnattendedRun
      K = Knowledge
      B = K::Boundary
      TERMINAL = %w[verified no_work stalled budget_exhausted verification_unavailable policy_violation needs_approval].freeze
      LIMITS = %w[max_attempts max_cost_microusd max_tokens run_seconds call_seconds cost_per_call_microusd tokens_per_call stall_limit].freeze

      def initialize(journal:, authorize:, escalations:, clock: -> { Time.now.utc })
        raise K::InvalidContract, "trusted authorizer, escalation outbox and clock required" unless authorize.respond_to?(:call) && clock.respond_to?(:call) && escalations.is_a?(Operations::Escalations)
        @journal, @authorize, @escalations, @clock = journal, authorize, escalations, clock
      end

      def start(id:, goal:, gates:, artifact:, allowed_resources:, protected_resources:, executor_version:, limits:, primary:, fallback:, context:, baseline_green: "no_work")
        guard!("start", context)
        unless goal.is_a?(Goal) && gates.is_a?(Array) && gates.size.between?(1, 16) && gates.all? { |g| g.is_a?(VerificationGate) && g.required? } && gates.map(&:id).uniq.size == gates.size
          raise K::InvalidContract, "goal and unique required gates needed"
        end
        required = (goal.criteria + goal.constraints).select(&:required?).map(&:id)
        raise K::InvalidContract, "every required goal criterion/constraint needs a gate" unless (required - gates.map(&:id)).empty?
        limits = B.data(limits)
        K::Snapshot.exact_keys!(limits, LIMITS)
        unless limits.values.all? { |v| v.is_a?(Integer) && v.positive? } && limits["call_seconds"] <= limits["run_seconds"] && limits["cost_per_call_microusd"] <= limits["max_cost_microusd"] && limits["tokens_per_call"] <= limits["max_tokens"] && limits["max_attempts"] <= 1000
          raise K::InvalidContract, "invalid bounded run limits"
        end
        [allowed_resources, protected_resources].each do |resources|
          raise K::InvalidContract, "nonempty unique resource allowlist/protected manifest required" unless resources.is_a?(Array) && resources.size.between?(1, 128) && resources.uniq == resources
          resources.each { |v| text(v) }
        end
        raise K::InvalidContract, "allowed and protected resources overlap" unless (allowed_resources & protected_resources).empty?
        unless (goal.protected_resources - protected_resources).empty? && (goal.max_steps.nil? || limits["max_attempts"] <= goal.max_steps)
          raise K::InvalidContract, "run cannot relax goal protections or step budget"
        end
        raise K::InvalidContract, "invalid baseline policy" unless %w[no_work continue].include?(baseline_green)
        contract = B.data(id: identifier(id), goal: goal.to_h, goal_digest: goal.digest, gates: gates.map { |g| g.to_h.merge("digest" => g.digest) },
          artifact: artifact_data(artifact), allowed_resources: allowed_resources, protected_resources: protected_resources,
          executor_version: text(executor_version), limits: limits, primary: text(primary), fallback: text(fallback), baseline_green: baseline_green)
        raise K::InvalidContract, "contract exceeds 256 KiB" if JSON.generate(contract).bytesize > 262_144
        result = model.transaction(requires_new: true) do
          row = rows(context).create_or_find_by!(run_key: key(id)) do |r|
            r.contract = contract
            r.contract_digest = K.digest(contract)
            r.runtime = { "status" => "awaiting_verification", "baseline" => true, "attempts" => 0,
              "charged_cost_microusd" => 0, "charged_tokens" => 0, "usage_complete" => true,
              "deadline_at" => (now + limits["run_seconds"]).iso8601(6), "artifact" => contract.fetch("artifact"),
              "lease" => nil, "worker_actors" => [], "streak" => 0, "receipt_keys" => [] }
          end
          row.with_lock do
            guard!("start", context)
            check!(row)
            raise K::IntegrityError, "run id reused with another contract" unless row.contract_digest == K.digest(contract)
            @journal.append(kind: "unattended", key: key(id, "contract"), payload: contract, context: context)
            snapshot(row)
          end
        end
        result || raise(K::IntegrityError, "run creation rolled back")
      end

      # Claim replay returns the same live lease only to its original principal.
      # After completion, replay returns state without another execution grant.
      def claim(id:, role:, request_id:, context:)
        raise K::InvalidContract, "role must be worker or verifier" unless %w[worker verifier].include?(role)
        guard!(role == "worker" ? "work" : "verify", context)
        # A savepoint cannot make a reservation durable before host execution.
        raise K::InvalidContract, "claim must run outside a caller transaction" if model.connection.transaction_open?
        request_id = identifier(request_id)
        actor = B.identity(context).fetch("principal")
        mutate(id, context) do |row, state|
          guard!(role == "worker" ? "work" : "verify", context)
          expire!(row, state, context)
          previous = @journal.read(kind: "unattended", key: key(id, "claim", request_id), context: context)
          if previous
            raise K::IntegrityError, "claim id reused by another role or principal" unless previous.values_at("role", "actor") == [role, actor]
            live = state["lease"] && state["lease"]["request_id"] == request_id && !TERMINAL.include?(state["status"])
            next snapshot(row, lease: live ? state["lease"] : nil)
          end
          next snapshot(row) if TERMINAL.include?(state["status"]) || state["lease"]
          required = state["status"] == "ready" ? "worker" : "verifier"
          raise K::InvalidContract, "wrong phase" unless required == role
          if role == "verifier" && state["worker_actors"].include?(actor)
            raise K::AccessDenied, "worker cannot verify its own run"
          end
          limits = row.contract.fetch("limits")
          if (role == "worker" && state["attempts"] >= limits["max_attempts"]) ||
              state["charged_cost_microusd"] + limits["cost_per_call_microusd"] > limits["max_cost_microusd"] ||
              state["charged_tokens"] + limits["tokens_per_call"] > limits["max_tokens"]
            stop!(row, state, "budget_exhausted", "admission_limit", context)
            next snapshot(row)
          end
          state["attempts"] += 1 if role == "worker"
          state["worker_actors"] |= [actor] if role == "worker"
          state["charged_cost_microusd"] += limits["cost_per_call_microusd"]
          state["charged_tokens"] += limits["tokens_per_call"]
          state["status"] = role == "worker" ? "working" : "verifying"
          state["lease"] = { "token" => SecureRandom.uuid, "request_id" => request_id, "role" => role, "actor" => actor,
            "issued_at" => now.iso8601(6), "expires_at" => [now + limits["call_seconds"], Time.iso8601(state["deadline_at"])].min.iso8601(6) }
          @journal.append(kind: "unattended", key: key(id, "claim", request_id),
            payload: state["lease"].except("token").merge("token_digest" => K.digest(state["lease"]["token"]), "attempt" => state["attempts"]), context: context)
          snapshot(row, lease: state["lease"])
        end
      end

      def report_work(id:, token:, artifact:, worker_claim:, usage:, context:, outcome: "completed")
        guard!("work", context)
        raise K::InvalidContract, "invalid work outcome" unless %w[completed needs_approval policy_violation].include?(outcome)
        report = B.data(artifact: artifact_data(artifact), worker_claim: text(worker_claim), usage: usage_data(usage), outcome: outcome)
        complete(id, token, "worker", report, context) do |row, state, _lease|
          state["artifact"] = report["artifact"]
          if !protected_match?(row, report["artifact"])
            stop!(row, state, "policy_violation", "protected_manifest_changed", context)
          elsif outcome != "completed"
            stop!(row, state, outcome, "worker_requested_stop", context)
          else
            state["status"] = "awaiting_verification"
          end
        end
      end

      # The verifier MUST independently inspect the immutable artifact and
      # protected resources; it must not copy the worker's manifest or assertions.
      def report_verification(id:, token:, artifact:, results:, failures:, progress_digest:, usage:, context:)
        guard!("verify", context)
        raise K::InvalidContract, "typed verification results required" unless results.is_a?(Array) && results.size <= 16 && results.all? { |v| v.is_a?(VerificationResult) }
        failures = B.data(failures)
        unless failures.is_a?(Array) && failures.size <= 32
          raise K::InvalidContract, "bounded failure diagnostics required"
        end
        failures.each do |failure|
          K::Snapshot.exact_keys!(failure, %w[gate_id code subject expected actual])
          failure.values.each { |v| text(v) }
        end
        report = B.data(artifact: artifact_data(artifact), results: results.map(&:to_h), failures: failures,
          progress_digest: digest(progress_digest), usage: usage_data(usage))
        complete(id, token, "verifier", report, context) do |row, state, lease|
          if report["artifact"] != state["artifact"] || !protected_match?(row, report["artifact"])
            stop!(row, state, "policy_violation", "independent_artifact_mismatch", context)
            next
          end
          gates = row.contract.fetch("gates")
          data = report["results"]
          valid = data.map { |r| r["gate_id"] }.sort == gates.map { |g| g["id"] }.sort && data.all? do |r|
            gate = gates.find { |g| g["id"] == r["gate_id"] }
            gate && r["gate_digest"] == gate["digest"] && r["commit_sha"] == report["artifact"]["commit_sha"] &&
              %w[configuration_digest dependencies_digest].all? { |field| r[field] == report["artifact"][field] } &&
              Time.iso8601(r["checked_at"]) >= Time.iso8601(lease["issued_at"]) && Time.iso8601(r["checked_at"]) <= now
          end
          if !valid || data.any? { |r| r["status"] == "pending" }
            stop!(row, state, "verification_unavailable", "missing_stale_or_pending_gates", context)
            next
          end
          failed_ids = data.select { |r| r["status"] == "failed" }.map { |r| r["gate_id"] }.sort
          unless failures.map { |f| f["gate_id"] }.uniq.sort == failed_ids
            stop!(row, state, "verification_unavailable", "incomplete_failure_diagnostics", context)
            next
          end
          baseline = state["baseline"]
          state["baseline"] = false
          if failed_ids.empty?
            if baseline && row.contract["baseline_green"] == "continue"
              state["status"] = "ready"
            else
              stop!(row, state, baseline ? "no_work" : "verified", "all_required_gates_passed", context)
            end
          else
            signature = K.digest(failures.sort_by { |f| K.digest(f) })
            unchanged = state["failure_signature"] == signature && state["progress_digest"] == progress_digest
            state["streak"] = !baseline && unchanged ? state["streak"] + 1 : 0
            state["failure_signature"], state["progress_digest"] = signature, progress_digest
            state["failures"] = failures
            if state["streak"] >= row.contract.fetch("limits")["stall_limit"]
              stop!(row, state, "stalled", "repeated_failure_without_observed_progress", context)
            else
              state["status"] = "ready"
            end
          end
        end
      end

      def fetch(id:, context:)
        guard!("read", context)
        row = rows(context).find_by(run_key: key(identifier(id)))
        row && (check!(row); snapshot(row))
      end

      def contract(id:, context:)
        guard!("read", context)
        row = rows(context).find_by!(run_key: key(identifier(id)))
        check!(row)
        B.data(row.contract)
      end

      def receipt(id:, token:, context:)
        guard!("read_history", context)
        @journal.read(kind: "unattended", key: key(identifier(id), "receipt", K.digest(text(token))), context: context)
      end

      def history(id:, context:, offset: 0, limit: 50)
        guard!("read_history", context)
        unless offset.is_a?(Integer) && offset >= 0 && limit.is_a?(Integer) && limit.between?(1, 100)
          raise K::InvalidContract, "bounded pagination required"
        end
        row = rows(context).find_by!(run_key: key(identifier(id)))
        check!(row)
        B.data(row.runtime.fetch("receipt_keys").drop(offset).first(limit).map do |ref|
          @journal.read(kind: "unattended", key: ref, context: context) || raise(K::IntegrityError, "missing attempt receipt")
        end)
      end

      def expire(id:, context:)
        guard!("expire", context)
        mutate(id, context) { |row, state| guard!("expire", context); expire!(row, state, context); snapshot(row) }
      end

      def due(context:, limit: 100)
        guard!("expire", context)
        raise K::InvalidContract, "limit must be 1..500" unless limit.is_a?(Integer) && limit.between?(1, 500)
        rows(context).where("runtime->>'status' IN (?)", %w[ready awaiting_verification working verifying])
          .where("(runtime->>'deadline_at')::timestamptz <= ? OR (runtime->'lease'->>'expires_at')::timestamptz <= ?", now, now)
          .order(:id).limit(limit).map { |row| check!(row); snapshot(row) }
      end

      def cancel(id:, reason:, context:)
        guard!("cancel", context)
        mutate(id, context) do |row, state|
          guard!("cancel", context)
          unless TERMINAL.include?(state["status"])
            state["usage_complete"] = false if state["lease"]
            stop!(row, state, "needs_approval", text(reason), context)
          end
          snapshot(row)
        end
      end

      private

      def now = @clock.call.utc
      def key(*parts) = K.digest(parts)
      def text(value)
        value = K.text(value)
        raise K::InvalidContract, "text exceeds 4096 bytes" if value.bytesize > 4096
        value
      end
      def identifier(value)
        value = text(value)
        raise K::InvalidContract, "identifier exceeds 128 bytes" if value.bytesize > 128
        value
      end
      def digest(value)
        Harness.valid_digest!(value)
      rescue ArgumentError
        raise K::InvalidContract, "sha256:<64 lowercase hex> digest required"
      end
      def artifact_data(value)
        data = B.data(value)
        K::Snapshot.exact_keys!(data, %w[commit_sha configuration_digest dependencies_digest protected_digest reference digest])
        commit = VerificationResult.normalize_commit_sha(data["commit_sha"])
        %w[configuration_digest dependencies_digest protected_digest digest].each { |f| digest(data[f]) }
        text(data["reference"])
        data.merge("commit_sha" => commit)
      end
      def usage_data(value)
        return nil if value.nil?
        data = B.data(value)
        K::Snapshot.exact_keys!(data, %w[cost_microusd tokens])
        raise K::InvalidContract, "nonnegative measured integer usage required" unless data.values.all? { |v| v.is_a?(Integer) && v >= 0 }
        data
      end
      def guard!(action, context)
        B.identity(context)
        raise K::AccessDenied, "unattended access denied" unless @authorize.call(action, context) == true
      end
      def model
        unless defined?(Agentkit::UnattendedRunRecord) && Agentkit::UnattendedRunRecord.table_exists?
          raise K::InvalidContract, "unattended runs require migration 031"
        end
        raise K::InvalidContract, "run and journal must share a pool" unless Agentkit::UnattendedRunRecord.connection_pool.equal?(@journal.model.connection_pool)
        unless defined?(Agentkit::OperationsEscalationRecord) && Agentkit::OperationsEscalationRecord.connection_pool.equal?(Agentkit::UnattendedRunRecord.connection_pool)
          raise K::InvalidContract, "run and escalation outbox must share a pool"
        end
        Agentkit::UnattendedRunRecord
      end
      def rows(context) = model.where(scope_key: B.scope(context))
      def check!(row)
        raise K::IntegrityError, "run contract changed" unless K.digest(row.contract) == row.contract_digest
      end
      def mutate(id, context)
        result = model.transaction(requires_new: true) do
          row = rows(context).find_by!(run_key: key(identifier(id)))
          row.lock!
          check!(row)
          output = yield(row, row.runtime)
          row.save!
          output
        end
        result || raise(K::IntegrityError, "run transaction rolled back")
      end
      def snapshot(row, lease: nil)
        state = row.runtime.except("lease", "receipt_keys", "worker_actors")
        B.data(state.merge("id" => row.contract["id"], "contract_digest" => row.contract_digest,
          "authorizes" => false, "lease" => lease, "usage_complete" => state["usage_complete"] && row.runtime["lease"].nil?,
          "completed_calls" => row.runtime.fetch("receipt_keys").size, "limits" => row.contract["limits"]))
      end
      def protected_match?(row, artifact)
        %w[configuration_digest dependencies_digest protected_digest].all? { |f| artifact[f] == row.contract.fetch("artifact")[f] }
      end

      def complete(id, token, role, report, context)
        actor = B.identity(context).fetch("principal")
        request = report.merge("actor" => actor, "role" => role)
        mutate(id, context) do |row, state|
          guard!(role == "worker" ? "work" : "verify", context)
          receipt_key = key(id, "receipt", K.digest(text(token)))
          @journal.once(kind: "unattended", key: receipt_key, request_digest: K.digest(request), context: context) do
            lease = state["lease"]
            unless lease && lease["token"] == token && lease["role"] == role && lease["actor"] == actor
              raise K::AccessDenied, "invalid lease owner or token"
            end
            expire!(row, state, context)
            state["receipt_keys"] << receipt_key
            if TERMINAL.include?(state["status"])
              request.merge("late" => true, "state" => snapshot(row))
            else
              state["lease"] = nil
              usage = report["usage"]
              limits = row.contract.fetch("limits")
              if usage.nil?
                state["usage_complete"] = false
                stop!(row, state, "needs_approval", "usage_unknown", context)
              else
                state["charged_cost_microusd"] += usage["cost_microusd"] - limits["cost_per_call_microusd"]
                state["charged_tokens"] += usage["tokens"] - limits["tokens_per_call"]
                if usage["cost_microusd"] > limits["cost_per_call_microusd"] || usage["tokens"] > limits["tokens_per_call"]
                  stop!(row, state, "budget_exhausted", "executor_exceeded_reserved_limit", context)
                else
                  yield(row, state, lease)
                end
              end
              request.merge("late" => false, "state" => snapshot(row))
            end
          end
        end
      end

      def expire!(row, state, context)
        return if TERMINAL.include?(state["status"])
        if now >= Time.iso8601(state["deadline_at"])
          state["usage_complete"] = false if state["lease"]
          stop!(row, state, "budget_exhausted", "absolute_deadline", context)
        elsif state["lease"] && now >= Time.iso8601(state["lease"]["expires_at"])
          state["usage_complete"] = false
          stop!(row, state, "needs_approval", "lease_expired_execution_unknown", context)
        end
      end

      def stop!(row, state, status, reason, context)
        state["status"], state["reason"], state["stopped_at"] = status, reason, now.iso8601(6)
        final = snapshot(row)
        @journal.append(kind: "unattended", key: key(row.contract["id"], "terminal"), payload: final, context: context)
        unless %w[verified no_work].include?(status)
          @escalations.enqueue(id: "unattended:#{row.contract['id']}", incident_id: row.contract["id"], incident_digest: K.digest(final),
            primary: row.contract["primary"], fallback: row.contract["fallback"], reasons: [status, reason], context: context)
        end
      end
    end
  end
end
