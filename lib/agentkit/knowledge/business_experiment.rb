# frozen_string_literal: true

require "openssl"

module Agentkit
  module Knowledge
    # Fixed-horizon, two-arm experiments. The host owns eligibility, unit
    # independence, treatment fidelity and business compensation, not the LLM.
    class BusinessExperiment
      ARMS = %w[control treatment].freeze
      attr_reader :protocol, :digest

      def initialize(name:, version:, hypothesis:, unit:, metrics:, primary_metric:,
                     starts_at:, enrollment_ends_at:, analysis_at:, window_seconds:,
                     max_units:, min_per_arm:, gates:, variants:, evidence_versions:, journal:,
                     authorize:, eligible:, bind_unit:, clock: -> { Time.now.utc })
        metrics, gates, evidence_versions = [metrics, gates, evidence_versions].map { |v| Boundary.data(v) }
        variants = Boundary.data(variants)
        unless variants.is_a?(Hash) && variants.keys.sort == ARMS && variants.values.all? { |v| v.is_a?(Hash) && !v.empty? }
          raise InvalidContract, "declarative control and treatment variants required"
        end
        validate_metrics!(metrics, primary_metric)
        unless gates.is_a?(Hash) && gates.keys.sort == ARMS && gates.values.all? { |v| v.is_a?(String) && !v.empty? }
          raise InvalidContract, "control and treatment gate digests required"
        end
        unless evidence_versions.is_a?(Hash) && !evidence_versions.empty? && evidence_versions.values.all? { |v| v.is_a?(String) && !v.empty? }
          raise InvalidContract, "versioned evidence dependencies required"
        end
        unless window_seconds.is_a?(Integer) && window_seconds.positive? &&
               max_units.is_a?(Integer) && max_units.between?(40, 10_000) &&
               min_per_arm.is_a?(Integer) && min_per_arm.between?(20, max_units / 2)
          raise InvalidContract, "bounded quota, observation window and minimum sample required"
        end
        starts_at, enrollment_ends_at, analysis_at = [starts_at, enrollment_ends_at, analysis_at].map { |t| Knowledge.timestamp(t) }
        unless Time.iso8601(starts_at) < Time.iso8601(enrollment_ends_at) &&
               Time.iso8601(analysis_at) >= Time.iso8601(enrollment_ends_at) + window_seconds
          raise InvalidContract, "analysis must follow enrollment plus outcome window"
        end
        raise InvalidContract, "trusted callbacks required" unless [authorize, eligible, bind_unit, clock].all? { |c| c.respond_to?(:call) }
        @protocol = Boundary.data(name: Knowledge.text(name), version: Knowledge.text(version),
          hypothesis: Knowledge.text(hypothesis), unit: Knowledge.text(unit), metrics: metrics,
          primary_metric: primary_metric, starts_at: starts_at, enrollment_ends_at: enrollment_ends_at,
          analysis_at: analysis_at, window_seconds: window_seconds, max_units: max_units,
          min_per_arm: min_per_arm, gates: gates, variants: variants, evidence_versions: evidence_versions,
          allocation: "hmac_sha256_50_50", analysis: "fixed_horizon_itt_bounded_hoeffding", confidence_basis_points: 9500)
        @digest = Knowledge.digest(protocol)
        @journal, @authorize, @eligible, @bind_unit, @clock = journal, authorize, eligible, bind_unit, clock
      end

      def register(context:)
        authorize!("register", context)
        output = nil
        model.transaction(requires_new: true) do
          row = relation(context).create_or_find_by!(experiment_key: experiment_key) do |record|
            raise InvalidContract, "register before enrollment starts" unless now < time("starts_at")
            record.definition, record.definition_digest = protocol, digest
            record.runtime = { "seed" => SecureRandom.hex(32), "units" => [] }
          end
          row.lock!
          validate_row!(row)
          authorize!("register", context)
          output = read("registration", context) || write("registration", {
            "protocol" => protocol, "registered_by" => actor(context),
            "seed_commitment" => Digest::SHA256.hexdigest(row.runtime.fetch("seed"))
          }, context)
          validate_seed!(row, context)
        end
        output || raise(IntegrityError, "experiment registration rolled back")
      end

      def approve(reason:, context:)
        locked("approve", context) do |row|
          registration = read!("registration", context)
          raise AccessDenied, "independent human reviewer required" if registration.fetch("registered_by") == actor(context)
          raise InvalidContract, "approval before enrollment required" unless now < time("starts_at")
          raise InvalidContract, "experiment not approvable" unless %w[draft approved].include?(row.status)
          result = write("approval", { "actor" => actor(context), "reason" => Knowledge.text(reason) }, context)
          row.update!(status: "approved")
          result
        end
      end

      def assign(unit_id:, context:)
        locked("assign", context) do |row|
          raise DecisionDenied, "experiment not approved" unless row.status == "approved"
          key = unit_key(unit_id)
          existing = read("assignment:#{key}", context)
          next existing if existing
          enrollment_open!
          raise AccessDenied, "unit not eligible" unless @eligible.call(unit_id, context) == true
          units = row.runtime.fetch("units")
          raise DecisionDenied, "experiment quota exhausted" if units.size >= protocol.fetch("max_units")
          bit = OpenSSL::HMAC.hexdigest("SHA256", row.runtime.fetch("seed"), "#{Boundary.scope(context)}:#{key}").to_i(16) % 2
          result = write("assignment:#{key}", { "unit_key" => key, "arm" => ARMS.fetch(bit) }, context)
          row.update!(runtime: row.runtime.merge("units" => units + [key]))
          result
        end
      end

      # Lock order: experiment -> source business row -> journal. Host effects
      # must be local, same-database writes (or an outbox), as with DecisionGate.
      def execute(unit_id:, gate:, arguments:, context:)
        arguments = Boundary.data(arguments)
        locked("execute", context) do |row|
          raise DecisionDenied, "experiment not approved" unless row.status == "approved"
          enrollment_open!
          raise AccessDenied, "unit no longer eligible" unless @eligible.call(unit_id, context) == true
          raise AccessDenied, "arguments do not belong to assigned unit" unless @bind_unit.call(unit_id, arguments, context) == true
          assignment = read!("assignment:#{unit_key(unit_id)}", context)
          arm = assignment.fetch("arm")
          unless gate.is_a?(DecisionGate) && gate.digest == protocol.fetch("gates").fetch(arm) && gate.journal.equal?(@journal)
            raise InvalidContract, "approved gate and shared journal required"
          end
          token = "#{digest}:#{assignment.fetch('unit_key')}"
          output = gate.execute(arguments: arguments, context: context,
                                operation: "business_experiment", idempotency_key: token) { yield arm, protocol.fetch("variants").fetch(arm) }
          receipt_key = "business_experiment:#{token}"
          receipt = @journal.read(kind: "execution", key: receipt_key, context: context)
          write("exposure:#{assignment.fetch('unit_key')}", {
            "arm" => arm, "execution_key" => receipt_key, "receipt_digest" => Knowledge.digest(receipt)
          }, context)
          { "arm" => arm, "output" => output, "execution_key" => receipt_key }
        end
      end

      # Outcomes are required for ALL assigned units, including non-exposed units.
      # Missing outcomes never become zero or silently disappear from analysis.
      def outcome(unit_id:, values:, source:, source_version:, observed_at:, context:)
        locked("outcome", context) do |row|
          raise InvalidContract, "analysis already sealed" if row.status == "analyzed"
          key = unit_key(unit_id)
          assignment = read!("assignment:#{key}", context)
          observed_at = Knowledge.timestamp(observed_at)
          observed = Time.iso8601(observed_at)
          unless observed >= Time.iso8601(assignment.fetch("recorded_at")) + protocol.fetch("window_seconds") && observed <= now
            raise InvalidContract, "final mature nonfuture outcome required"
          end
          values = Boundary.data(values)
          unless values.is_a?(Hash) && values.keys.sort == protocol.fetch("metrics").keys.sort && values.all? { |name, value|
            metric = protocol.fetch("metrics").fetch(name)
            value.is_a?(Integer) && value.between?(metric.fetch("min"), metric.fetch("max"))
          }
            raise InvalidContract, "complete bounded integer outcomes required"
          end
          write("outcome:#{key}", { "values" => values, "source" => Knowledge.text(source),
            "source_version" => Knowledge.text(source_version), "observed_at" => observed_at }, context)
        end
      end

      def stop(reason:, context:)
        locked("stop", context) do |row|
          raise InvalidContract, "analysis already sealed" if row.status == "analyzed"
          result = write("stop", { "actor" => actor(context), "reason" => Knowledge.text(reason) }, context)
          row.update!(status: "stopped")
          result
        end
      end

      def analyze(context:)
        locked("analyze", context) do |row|
          existing = read("analysis", context)
          next existing if existing
          raise InvalidContract, "fixed analysis horizon not reached" unless now >= time("analysis_at")
          rows = row.runtime.fetch("units").sort.map do |key|
            assignment = read!("assignment:#{key}", context)
            outcome = read("outcome:#{key}", context)
            available = outcome && %w[observed_at recorded_at].all? { |field| Time.iso8601(outcome.fetch(field)) <= time("analysis_at") }
            { "assignment" => assignment, "outcome" => available ? outcome : nil,
              "exposure" => read("exposure:#{key}", context) }
          end
          result = write("analysis", summarize(rows, stopped: !!read("stop", context), approved: !!read("approval", context)), context)
          row.update!(status: "analyzed")
          result
        end
      end

      def fetch(type:, context:, unit_id: nil)
        allowed = %w[registration approval stop analysis assignment exposure outcome final_review revocation]
        raise InvalidContract, "unknown experiment record" unless allowed.include?(type)
        locked("read", context) do |_row|
          suffix = %w[assignment exposure outcome].include?(type) ? ":#{unit_key(unit_id)}" : ""
          read("#{type}#{suffix}", context)
        end
      end

      def review_result(approve:, reason:, context:)
        locked("review_result", context) do |row|
          raise InvalidContract, "boolean approval required" unless [true, false].include?(approve)
          report = read!("analysis", context)
          if approve && report.fetch("status") != "eligible_for_human_review"
            raise DecisionDenied, "inconclusive experiment cannot be approved"
          end
          if actor(context) == read!("registration", context).fetch("registered_by")
            raise AccessDenied, "independent human reviewer required"
          end
          raise DecisionDenied, "result revoked" if read("revocation", context)
          write("final_review", { "approved" => approve, "actor" => actor(context),
            "reason" => Knowledge.text(reason), "report_digest" => Knowledge.digest(report), "auto_promoted" => false }, context)
        end
      end

      def revoke_result(reason:, context:)
        locked("revoke_result", context) do |_row|
          read!("analysis", context)
          write("revocation", { "actor" => actor(context), "reason" => Knowledge.text(reason) }, context)
        end
      end

      private

      def validate_metrics!(metrics, primary)
        unless metrics.is_a?(Hash) && metrics.size.between?(1, 16) && metrics.key?(primary) && metrics.all? { |name, m|
          name.is_a?(String) && !name.empty? && m.is_a?(Hash) &&
            (m.keys - %w[min max direction max_harm]).empty? && %w[minimize maximize].include?(m["direction"]) &&
            m["min"].is_a?(Integer) && m["max"].is_a?(Integer) && m["min"] < m["max"] &&
            m["min"].abs <= 1_000_000_000_000 && m["max"].abs <= 1_000_000_000_000 &&
            (!m.key?("max_harm") || (m["max_harm"].is_a?(Integer) && m["max_harm"] >= 0))
        }
          raise InvalidContract, "predefined primary metric and bounded metric contracts required"
        end
      end

      def summarize(rows, stopped:, approved:)
        groups = ARMS.to_h { |arm| [arm, rows.select { |r| r["assignment"]["arm"] == arm }] }
        counts = groups.transform_values do |group|
          { "assigned" => group.size, "complete" => group.count { |r| r["outcome"] },
            "missing" => group.count { |r| !r["outcome"] }, "exposed" => group.count { |r| r["exposure"] } }
        end
        reasons = []
        reasons << "stopped" if stopped
        reasons << "not_approved" unless approved
        reasons << "insufficient_sample" if counts.values.any? { |c| c["assigned"] < protocol.fetch("min_per_arm") }
        reasons << "missing_outcomes" if counts.values.any? { |c| c["missing"].positive? }
        n = rows.size
        imbalance_bound = n.zero? ? 1.0 : [1.0, 2.0 * Math.exp(-2.0 * (counts["control"]["assigned"] - n / 2.0)**2 / n)].min
        reasons << "allocation_imbalance" if imbalance_bound < 0.001
        estimates = {}
        if counts.values.all? { |c| c["complete"].positive? && c["missing"].zero? }
          protocol.fetch("metrics").each do |name, metric|
            means = groups.transform_values { |g| g.sum { |r| r["outcome"]["values"][name] }.fdiv(g.size) }
            radius = groups.values.sum { |g| (metric["max"] - metric["min"]) * Math.sqrt(Math.log(4.0 * protocol.fetch("metrics").size / 0.05) / (2 * g.size)) }
            effect = means["treatment"] - means["control"]
            benefit = metric["direction"] == "maximize" ? effect : -effect
            estimates[name] = { "means" => means.transform_values { |v| decimal(v) },
              "treatment_minus_control" => decimal(effect), "benefit_lower" => decimal(benefit - radius),
              "benefit_upper" => decimal(benefit + radius), "method" => "simultaneous_bounded_hoeffding_95" }
            reasons << "primary_inconclusive" if name == protocol.fetch("primary_metric") && benefit - radius <= 0
            reasons << "guardrail_not_established:#{name}" if metric.key?("max_harm") && benefit - radius < -metric.fetch("max_harm")
          end
        end
        { "protocol" => protocol, "counts" => counts, "rows" => rows, "estimates" => estimates,
          "imbalance_tail_bound" => decimal(imbalance_bound), "reasons" => reasons,
          "status" => reasons.empty? ? "eligible_for_human_review" : "inconclusive",
          "estimand" => "intention_to_treat", "auto_promoted" => false, "causal_proof" => false,
          "assumptions" => %w[independent_units no_interference faithful_assignment complete_outcomes stable_measurement] }
      end

      def decimal(value) = format("%.15g", value)
      def now = @clock.call.utc
      def time(field) = Time.iso8601(protocol.fetch(field))
      def actor(context) = Boundary.identity(context).fetch("principal")
      def unit_key(id) = Knowledge.digest("unit" => Knowledge.text(id))
      def experiment_key = Knowledge.digest(protocol.slice("name", "version"))

      def enrollment_open!
        raise DecisionDenied, "outside enrollment window" unless now >= time("starts_at") && now < time("enrollment_ends_at")
      end

      def authorize!(action, context)
        Boundary.identity(context)
        raise AccessDenied, "experiment access denied" unless @authorize.call(action, context) == true
      end

      def model
        unless defined?(Agentkit::BusinessExperimentRecord) && Agentkit::BusinessExperimentRecord.table_exists?
          raise InvalidContract, "business experiments require migration 025"
        end
        klass = Agentkit::BusinessExperimentRecord
        raise InvalidContract, "shared journal connection required" unless klass.connection_pool == @journal.model.connection_pool
        klass
      end

      def relation(context) = model.where(scope_key: Boundary.scope(context))

      def validate_row!(row)
        unless row.definition_digest == digest && Knowledge.digest(row.definition) == digest
          raise IntegrityError, "experiment name/version already bound to another protocol"
        end
      end

      def validate_seed!(row, context)
        commitment = read!("registration", context).fetch("seed_commitment")
        unless Digest::SHA256.hexdigest(row.runtime.fetch("seed")) == commitment
          raise IntegrityError, "experiment randomization seed changed"
        end
      end

      def locked(action, context)
        authorize!(action, context)
        output = nil
        model.transaction(requires_new: true) do
          row = relation(context).lock.find_by!(experiment_key: experiment_key)
          validate_row!(row)
          validate_seed!(row, context)
          authorize!(action, context)
          output = { value: yield(row) }
        end
        raise IntegrityError, "experiment transaction rolled back" unless output
        output.fetch(:value)
      end

      def read(key, context) = @journal.read(kind: "experiment", key: "#{digest}:#{key}", context: context)
      def read!(key, context) = read(key, context) || raise(InvalidContract, "missing experiment #{key}")

      def write(key, payload, context)
        payload = Boundary.data(payload).merge("protocol_digest" => digest)
        @journal.once(kind: "experiment", key: "#{digest}:#{key}", request_digest: Knowledge.digest(payload), context: context) do
          payload.merge("recorded_at" => now.iso8601(6))
        end
      end
    end
  end
end
