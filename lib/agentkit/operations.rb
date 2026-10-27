# frozen_string_literal: true

module Agentkit
  module Operations
    K = Knowledge
    B = Knowledge::Boundary

    class Catalog < K::Record
      def initialize(name:, version:, services:)
        services = B.data(services)
        unless services.is_a?(Hash) && services.size.between?(1, 256)
          raise K::InvalidContract, "bounded service catalog required"
        end
        services.each do |id, service|
          K.text(id)
          K::Snapshot.exact_keys!(service, %w[owner on_call dependencies runbooks slo sources])
          %w[owner on_call].each { |field| K.text(service.fetch(field)) }
          dependencies = service.fetch("dependencies")
          unless dependencies.is_a?(Array) && dependencies.uniq == dependencies && (dependencies - services.keys).empty?
            raise K::InvalidContract, "dependencies must reference catalog services"
          end
          unless service["runbooks"].is_a?(Array) && service["runbooks"].size.between?(1, 32) && service["slo"].is_a?(Hash) && !service["slo"].empty?
            raise K::InvalidContract, "versioned runbooks and SLO definition required"
          end
          service["runbooks"].each do |runbook|
            K::Snapshot.exact_keys!(runbook, %w[reference version])
            runbook.values.each { |v| K.text(v) }
          end
          unless service["sources"].is_a?(Hash) && service["sources"].size.between?(1, 16)
            raise K::InvalidContract, "required evidence sources must be declared"
          end
          service["sources"].each do |source, freshness|
            K.text(source)
            raise K::InvalidContract, "positive source freshness in seconds required" unless freshness.is_a?(Integer) && freshness.positive?
          end
        end
        payload = { "name" => K.text(name), "version" => K.text(version), "services" => services }
        raise K::InvalidContract, "catalog exceeds 1 MiB" if JSON.generate(payload).bytesize > 1_048_576
        super(payload)
      end

      def service(id) = data.fetch("services").fetch(id) { raise K::InvalidContract, "unknown service" }
    end

    class Monitor
      def initialize(catalog:, journal:, authorize:, loader:, verifier:, verifier_version:, clock: -> { Time.now.utc }, ack_timeout: 900)
        unless catalog.is_a?(Catalog) && [authorize, loader, verifier, clock].all? { |c| c.respond_to?(:call) }
          raise K::InvalidContract, "catalog and trusted callbacks required"
        end
        @catalog, @journal, @authorize, @loader, @verifier, @clock = catalog, journal, authorize, loader, verifier, clock
        @verifier_version = K.text(verifier_version)
        @escalations = Escalations.new(journal: journal, authorize: authorize, clock: clock, ack_timeout: ack_timeout)
      end

      attr_reader :escalations

      def capture(id:, service:, environment:, from:, to:, context:)
        guard!("capture", context)
        contract = @catalog.service(service)
        from, to = K.timestamp(from), K.timestamp(to)
        raise K::InvalidContract, "invalid incident window" unless from <= to && Time.iso8601(to) <= now
        request = B.data(id: K.text(id), service: service, environment: K.text(environment), from: from, to: to, catalog_digest: @catalog.digest)
        result = @journal.model.transaction(requires_new: true) do
          incident = @journal.once(kind: "operations", key: "incident:#{id}", request_digest: K.digest(request), context: context) do
            coverage, evidence = {}, []
            contract.fetch("sources").each do |source, freshness|
              begin
                response = B.data(@loader.call(request.merge("source" => source, "scope" => B.scope(context)), context))
                raise K::AccessDenied, "source scope mismatch" unless response.is_a?(Hash) && response["scope"] == B.scope(context)
                K::Snapshot.exact_keys!(response, %w[scope status observed_at items])
                raise K::InvalidContract, "unknown source status" unless %w[ok unavailable].include?(response["status"])
                if response["status"] == "unavailable"
                  coverage[source] = { "status" => "unavailable" }
                  next
                end
                observed = Time.iso8601(K.timestamp(response.fetch("observed_at")))
                if observed > now || observed + freshness < now
                  coverage[source] = { "status" => "stale" }
                  next
                end
                items = response.fetch("items")
                raise K::InvalidContract, "bounded evidence array required" unless items.is_a?(Array) && items.size <= 500
                validated = items.map { |item| evidence_item(item, request, source) }
                evidence.concat(validated)
                coverage[source] = { "status" => "available", "observed_at" => observed.iso8601(6), "count" => items.size }
              rescue K::AccessDenied
                raise
              rescue StandardError => error
                coverage[source] = { "status" => "unavailable", "error_class" => error.class.name }
              end
            end
            reasons = coverage.filter_map { |source, status| "source:#{source}:#{status['status']}" unless status["status"] == "available" }
            reasons << "missing_deployed_change_context" unless evidence.any? { |e| e["kind"] == "deployment" }
            request.merge("catalog" => @catalog.to_h, "coverage" => coverage, "evidence" => evidence.uniq { |e| e["id"] }.sort_by { |e| [e["at"], e["id"]] },
              "reasons" => reasons, "status" => reasons.empty? ? "observed" : "needs_help", "captured_at" => now.iso8601(6), "authorizes" => false)
          end
          if incident["status"] == "needs_help"
            @escalations.enqueue(id: "incident:#{id}", incident_id: id, incident_digest: K.digest(incident),
              primary: contract.fetch("on_call"), fallback: contract.fetch("owner"), reasons: incident.fetch("reasons"), context: context)
          end
          incident
        end
        result || raise(K::IntegrityError, "incident transaction rolled back")
      end

      def recommend(id:, incident_id:, observations:, hypotheses:, checks:, proposed_fix:, context:)
        guard!("recommend", context)
        incident = fetch(type: "incident", id: incident_id, context: context) || raise(K::InvalidContract, "unknown incident")
        raise K::IntegrityError, "catalog changed; recapture evidence" unless incident["catalog_digest"] == @catalog.digest
        payload = B.data(observations: observations, hypotheses: hypotheses, checks: checks, proposed_fix: proposed_fix)
        validate_recommendation!(payload, incident)
        request = payload.merge("incident_digest" => K.digest(incident), "incident_id" => incident_id, "id" => K.text(id), "verifier_version" => @verifier_version)
        result = @journal.model.transaction(requires_new: true) do
          recommendation = @journal.once(kind: "operations", key: "recommendation:#{id}", request_digest: K.digest(request), context: context) do
            reasons = incident.fetch("reasons").dup
            @catalog.service(incident.fetch("service")).fetch("sources").each do |source, freshness|
              observed = incident.fetch("coverage").fetch(source)["observed_at"]
              reasons << "source:#{source}:expired" if observed && Time.iso8601(observed) + freshness < now
            end
            begin
              verdict = B.data(@verifier.call(K.copy(request.merge("incident" => incident)), context))
              K::Snapshot.exact_keys!(verdict, %w[accepted reasons])
              unless [true, false].include?(verdict["accepted"]) && verdict["reasons"].is_a?(Array) && verdict["reasons"].all? { |r| r.is_a?(String) }
                raise K::InvalidContract, "invalid verifier verdict"
              end
              reasons.concat(verdict["reasons"])
              reasons << "verification_rejected" unless verdict["accepted"]
            rescue K::AccessDenied
              raise
            rescue StandardError => error
              reasons << "verifier_unavailable:#{error.class.name}"
            end
            request.merge("status" => reasons.empty? ? "verified_recommendation" : "needs_help", "reasons" => reasons.uniq,
              "recorded_at" => now.iso8601(6), "authorizes" => false, "causal_proof" => false)
          end
          if recommendation["status"] == "needs_help"
            contract = @catalog.service(incident.fetch("service"))
            @escalations.enqueue(id: "recommendation:#{id}", incident_id: incident_id, incident_digest: K.digest(incident),
              primary: contract.fetch("on_call"), fallback: contract.fetch("owner"), reasons: recommendation.fetch("reasons"), context: context)
          end
          recommendation
        end
        result || raise(K::IntegrityError, "recommendation transaction rolled back")
      end

      def fetch(type:, id:, context:)
        guard!("read", context)
        raise K::InvalidContract, "unknown operations record" unless %w[incident recommendation].include?(type)
        @journal.read(kind: "operations", key: "#{type}:#{K.text(id)}", context: context)
      end

      private

      def now = @clock.call.utc
      def guard!(action, context)
        B.identity(context)
        raise K::AccessDenied, "operations access denied" unless @authorize.call(action, context) == true
      end

      def evidence_item(item, request, source)
        K::Snapshot.exact_keys!(item, %w[kind at reference version data])
        raise K::InvalidContract, "unknown evidence kind" unless %w[log metric trace deployment configuration].include?(item["kind"])
        at = K.timestamp(item.fetch("at"))
        unless at <= request.fetch("to") && (item["kind"] == "deployment" || at >= request.fetch("from")) && item["data"].is_a?(Hash)
          raise K::InvalidContract, "evidence outside incident window"
        end
        K.text(item.fetch("reference")); K.text(item.fetch("version"))
        if item["kind"] == "deployment"
          data = item.fetch("data")
          %w[repository base_sha deployed_sha diff_reference diff_digest service environment].each { |field| K.text(data.fetch(field)) }
          unless data["service"] == request["service"] && data["environment"] == request["environment"] &&
                 %w[base_sha deployed_sha].all? { |key| /\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/.match?(data[key]) } &&
                 data["diff"].is_a?(String) && Digest::SHA256.hexdigest(data["diff"]) == data["diff_digest"]
            raise K::InvalidContract, "deployment must bind service, environment and exact revisions"
          end
        end
        payload = item.merge("at" => at, "source" => source)
        raise K::InvalidContract, "evidence item exceeds 64 KiB" if JSON.generate(payload).bytesize > 65_536
        payload.merge("id" => K.digest(payload))
      end

      def validate_recommendation!(payload, incident)
        known = incident.fetch("evidence").map { |e| e.fetch("id") }
        %w[observations hypotheses checks].each do |group|
          items = payload.fetch(group)
          raise K::InvalidContract, "bounded nonempty recommendation sections required" unless items.is_a?(Array) && items.size.between?(1, 32)
          items.each do |item|
            fields = group == "hypotheses" ? %w[text supporting_ids opposing_ids] : (group == "checks" ? %w[text evidence_ids read_only] : %w[text evidence_ids])
            K::Snapshot.exact_keys!(item, fields)
            K.text(item.fetch("text"))
            refs = group == "hypotheses" ? %w[supporting_ids opposing_ids] : %w[evidence_ids]
            refs.each do |field|
              ids = item.fetch(field)
              unless ids.is_a?(Array) && ids.uniq == ids && (ids - known).empty? && ids.size <= 64
                raise K::InvalidContract, "unresolved evidence references"
              end
            end
            raise K::InvalidContract, "observations require evidence" if group == "observations" && item["evidence_ids"].empty?
            raise K::InvalidContract, "diagnostic checks must be read-only" if group == "checks" && item["read_only"] != true
          end
        end
        fix = payload.fetch("proposed_fix")
        K::Snapshot.exact_keys!(fix, %w[description risk preconditions rollback])
        %w[description rollback].each { |key| K.text(fix.fetch(key)) }
        unless %w[low medium high].include?(fix["risk"]) && fix["preconditions"].is_a?(Array) && fix["preconditions"].size.between?(1, 32)
          raise K::InvalidContract, "risk and preconditions required"
        end
        fix["preconditions"].each { |v| K.text(v) }
      end
    end

    # Offline acceptance tests. Expected values are never passed to the runner.
    class Replay
      def self.evaluate(cases:, runner:)
        cases = B.data(cases)
        unless cases.is_a?(Array) && cases.size.between?(1, 1000) && runner.respond_to?(:call)
          raise K::InvalidContract, "bounded replay cases and runner required"
        end
        ids = cases.map { |c| K.text(c.fetch("id")) }
        raise K::InvalidContract, "duplicate replay cases" unless ids.uniq == ids
        results = cases.map do |test|
          K::Snapshot.exact_keys!(test, %w[id input expected_status required_evidence_ids])
          unless %w[needs_help verified_recommendation].include?(test["expected_status"]) && test["required_evidence_ids"].is_a?(Array) &&
                 test["required_evidence_ids"].all? { |v| v.is_a?(String) && !v.empty? } && test["required_evidence_ids"].uniq == test["required_evidence_ids"]
            raise K::InvalidContract, "invalid replay expectation"
          end
          begin
            output = B.data(runner.call(test.fetch("input")))
            references = output.fetch("observations").flat_map { |o| o.fetch("evidence_ids") }
            passed = output["status"] == test["expected_status"] && (test["required_evidence_ids"] - references).empty? && output["authorizes"] == false && output["causal_proof"] == false
            { "id" => test["id"], "passed" => passed, "output_digest" => K.digest(output) }
          rescue StandardError => error
            { "id" => test["id"], "passed" => false, "error_class" => error.class.name }
          end
        end
        B.data(cases_digest: K.digest(cases), total: results.size, passed: results.count { |r| r["passed"] }, results: results,
          guarantee: "contract_replay_not_production_competence")
      end
    end
  end
end

require_relative "operations/escalations"
