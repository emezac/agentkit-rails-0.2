# frozen_string_literal: true

module Agentkit
  module Knowledge
    # Retrospective evidence, deliberately separate from causal experiments and
    # Exploration's statistically significant holdout promotion contract.
    class BusinessLearning
      RECORD_TYPES = %w[observation outcome report proposal review rollback].freeze
      attr_reader :contract, :digest

      def initialize(name:, version:, objective:, metrics:, constraints:, window_seconds:, evidence_versions:,
                     journal:, authorize:, clock: -> { Time.now.utc })
        raise InvalidContract, "positive observation window required" unless window_seconds.is_a?(Integer) && window_seconds.positive?
        metrics = Boundary.data(metrics)
        unless metrics.is_a?(Hash) && !metrics.empty? && metrics.values.all? { |v| %w[minimize maximize].include?(v) }
          raise InvalidContract, "metrics must map names to minimize/maximize"
        end
        raise InvalidContract, "callbacks required" unless authorize.respond_to?(:call) && clock.respond_to?(:call)
        evidence_versions = Boundary.data(evidence_versions)
        unless evidence_versions.is_a?(Hash) && !evidence_versions.empty? && evidence_versions.values.all? { |v| v.is_a?(String) && !v.empty? }
          raise InvalidContract, "explicit evidence dependency versions required"
        end
        @contract = Boundary.data(name: Knowledge.text(name), version: Knowledge.text(version),
                                  objective: Knowledge.text(objective), metrics: metrics,
                                  constraints: constraints, window_seconds: window_seconds,
                                  evidence_versions: Boundary.data(evidence_versions))
        @digest = Knowledge.digest(contract)
        @journal, @authorize, @clock = journal, authorize, clock
      end

      # Capture only committed, executed decisions. Snapshot time is authoritative;
      # the host must ensure extraction includes no future information.
      def observe(id:, execution_key:, context:, applied_proposal_id: nil)
        guard!("observe", context)
        receipt = @journal.read(kind: "execution", key: execution_key, context: context)
        raise InvalidContract, "executed receipt required" unless receipt && receipt["status"] == "executed"
        verdict = receipt.fetch("verdict")
        raise InvalidContract, "accepted decision required" unless verdict["accepted"] == true
        expected_gate = contract.fetch("evidence_versions")["gate"]
        if expected_gate && verdict["gate_digest"] != expected_gate
          raise InvalidContract, "execution gate differs from process dependency"
        end
        snapshot = @journal.load_snapshot(verdict.fetch("snapshot_digest"), context: context)
        raise IntegrityError, "missing decision snapshot" unless snapshot
        applied = applied_proposal_id && active(id: applied_proposal_id, context: context)
        raise InvalidContract, "proposal not active" if applied_proposal_id && !applied
        put("observation", id, { execution_key: execution_key, receipt_digest: Knowledge.digest(receipt),
                                 applied_proposal_id: applied_proposal_id, applied_proposal_digest: applied && Knowledge.digest(applied),
                                 snapshot_digest: snapshot.digest, gate_digest: verdict.fetch("gate_digest"),
                                 decided_at: snapshot.data.fetch("at") }, context)
      end

      # One immutable final outcome per decision; partial events stay in the host
      # inbox. Corrections require a new contract version and explicit re-evaluation.
      def outcome(id:, values:, source:, source_version:, observed_at:, context:)
        guard!("outcome", context)
        observation = get!("observation", id, context)
        now = time_now
        observed = Time.iso8601(Knowledge.timestamp(observed_at))
        mature = Time.iso8601(observation.fetch("decided_at")) + contract.fetch("window_seconds")
        raise InvalidContract, "outcome must be final, mature and not future dated" unless observed >= mature && observed <= now
        values = Boundary.data(values)
        unless values.is_a?(Hash) && values.keys.sort == contract.fetch("metrics").keys.sort && values.values.all? { |v| v.is_a?(Integer) }
          raise InvalidContract, "all metrics required as integer units"
        end
        payload = { values: values, source: Knowledge.text(source), source_version: Knowledge.text(source_version),
                    observed_at: Knowledge.timestamp(observed_at) }
        put("outcome", id, payload, context)
      end

      def evaluate(id:, observation_ids:, split_at:, as_of:, context:)
        guard!("evaluate", context)
        split, cutoff = [split_at, as_of].map { |t| Time.iso8601(Knowledge.timestamp(t)) }
        raise InvalidContract, "invalid temporal split" unless split < cutoff && cutoff <= time_now
        unless observation_ids.is_a?(Array) && observation_ids.size.between?(1, 10_000) &&
               observation_ids.all? { |id| id.is_a?(String) && !id.empty? } && observation_ids.uniq == observation_ids
          raise InvalidContract, "unique bounded observation IDs required"
        end
        rows = observation_ids.sort.map do |key|
          observation = get!("observation", key, context)
          decided = Time.iso8601(observation.fetch("decided_at"))
          raise InvalidContract, "decision after report cutoff" if decided > cutoff
          partition = decided < split ? "training" : "holdout"
          boundary = partition == "training" ? split : cutoff
          outcome = get("outcome", key, context)
          state = if decided + contract.fetch("window_seconds") > boundary
                    "pending"
                  elsif !outcome || %w[observed_at journaled_at].any? { |field| Time.iso8601(outcome.fetch(field)) > boundary }
                    "missing"
                  else
                    "complete"
                  end
          { "id" => key, "partition" => partition, "state" => state,
            "observation" => observation, "outcome" => state == "complete" ? outcome : nil }
        end
        execution_keys = rows.map { |row| row.fetch("observation").fetch("execution_key") }
        raise InvalidContract, "duplicate execution in cohort" unless execution_keys.uniq == execution_keys
        summaries = %w[training holdout].to_h do |partition|
          selected = rows.select { |row| row["partition"] == partition }
          complete = selected.select { |row| row["state"] == "complete" }
          [partition, { "counts" => %w[complete pending missing].to_h { |s| [s, selected.count { |r| r["state"] == s }] },
                        "metrics" => contract.fetch("metrics").keys.to_h { |m| [m, { "sum" => complete.sum { |r| r["outcome"]["values"][m] }, "count" => complete.size }] } }]
        end
        put("report", id, { split_at: split.iso8601(6), as_of: cutoff.iso8601(6), rows: rows,
                            summaries: summaries, causal: false, selection: "host_supplied_cohort" }, context)
      end

      def propose(id:, report_id:, hypothesis:, change:, expires_at:, context:)
        guard!("propose", context)
        report = get!("report", report_id, context)
        unless %w[training holdout].all? { |p| report["summaries"][p]["counts"]["complete"].positive? }
          raise InvalidContract, "completed training and holdout evidence required"
        end
        expires = Knowledge.timestamp(expires_at)
        raise InvalidContract, "future expiry required" unless Time.iso8601(expires) > time_now
        change = Boundary.data(change)
        raise InvalidContract, "declarative change object required" unless change.is_a?(Hash) && !change.empty?
        put("proposal", id, { report_id: report_id, report_digest: Knowledge.digest(report),
                              hypothesis: Knowledge.text(hypothesis), change: change, expires_at: expires,
                              proposed_by: Boundary.identity(context).fetch("principal"), causal: false }, context)
      end

      def review(id:, approve:, reason:, context:)
        guard!("review", context)
        raise InvalidContract, "boolean approval required" unless [true, false].include?(approve)
        proposal = get!("proposal", id, context)
        actor = Boundary.identity(context).fetch("principal")
        raise AccessDenied, "independent reviewer required" if actor == proposal.fetch("proposed_by")
        fresh!(proposal) if approve
        put("review", id, { approved: approve, actor: actor, reason: Knowledge.text(reason),
                            proposal_digest: Knowledge.digest(proposal) }, context)
      end

      def rollback(id:, reason:, context:)
        guard!("rollback", context)
        get!("proposal", id, context)
        put("rollback", id, { actor: Boundary.identity(context).fetch("principal"), reason: Knowledge.text(reason) }, context)
      end

      # Approval permits the host to consider this version. It neither registers
      # a Knowledge::Rule nor executes a business effect. Always recheck at use.
      def active(id:, context:)
        guard!("use", context)
        proposal = get!("proposal", id, context)
        fresh!(proposal)
        review = get("review", id, context)
        return nil unless review && review["approved"] && !get("rollback", id, context)
        raise IntegrityError, "review mismatch" unless review["proposal_digest"] == Knowledge.digest(proposal)
        proposal
      end

      def fetch(type:, id:, context:)
        guard!("read", context)
        raise InvalidContract, "unknown learning record type" unless RECORD_TYPES.include?(type)
        get(type, id, context)
      end

      private

      def time_now = @clock.call.utc

      def guard!(action, context)
        Boundary.identity(context)
        raise AccessDenied, "business learning denied" unless @authorize.call(action, context) == true
      end

      def fresh!(proposal)
        raise InvalidContract, "proposal expired" unless Time.iso8601(proposal.fetch("expires_at")) > time_now
      end

      def key(type, id) = "business:#{digest}:#{type}:#{Knowledge.text(id)}"

      def get(type, id, context)
        @journal.read(kind: "learning", key: key(type, id), context: context)
      end

      def get!(type, id, context)
        get(type, id, context) || raise(InvalidContract, "unknown #{type} for this process version")
      end

      def put(type, id, payload, context)
        payload = Boundary.data(payload).merge("process_digest" => digest, "process_contract" => contract)
        @journal.once(kind: "learning", key: key(type, id), request_digest: Knowledge.digest(payload), context: context) do
          payload.merge("journaled_at" => time_now.iso8601(6))
        end
      end
    end
  end
end
