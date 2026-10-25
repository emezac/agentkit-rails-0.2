# frozen_string_literal: true

module Agentkit
  module Knowledge
    class DecisionGate
      attr_reader :name, :source, :journal, :digest

      def initialize(name:, version:, source:, journal:, queries:, authorize:, execution_context: nil,
                     require_complete: true, limits: {})
        Knowledge.text(name)
        Knowledge.text(version)
        unless source.is_a?(ActiveRecordSource) && journal.is_a?(Journal) &&
               queries.respond_to?(:call) && authorize.respond_to?(:call)
          raise InvalidContract, "gate requires Rails source, journal, queries and authorizer"
        end
        unless [true, false].include?(require_complete) && (execution_context.nil? || execution_context.respond_to?(:call))
          raise InvalidContract, "invalid gate configuration"
        end
        @name, @source, @journal = Knowledge.text(name), source, journal
        @queries, @authorize, @execution_context = queries, authorize, execution_context
        @require_complete, @engine = require_complete, Engine.new(**limits)
        @digest = Knowledge.digest("name" => name, "version" => version, "source" => source.contract,
                                   "require_complete" => require_complete, "limits" => Boundary.data(limits))
        freeze
      end

      # The host resolves the original requester's current permissions/account
      # on workers. Never authorize the privileged system executor implicitly.
      def context_for(proposal)
        raise AccessDenied, "gate requires execution_context resolver for Actions" unless @execution_context
        context = @execution_context.call(proposal)
        identity = Boundary.identity(context)
        unless identity.fetch("tenant") == proposal.tenant_key && identity.fetch("principal") == proposal.requester_principal_id
          raise AccessDenied, "execution context differs from approved requester"
        end
        context
      end

      def claims(arguments, context)
        payload = Boundary.data(@queries.call(Boundary.data(arguments), context))
        unless payload.is_a?(Array) && !payload.empty? && payload.size <= 32 && payload.uniq == payload &&
               payload.all? { |query| query.is_a?(Hash) && query.keys.sort == %w[relation values] &&
                 query["relation"].is_a?(String) && query["values"].is_a?(Array) }
          raise InvalidContract, "queries must be unique bounded relation/values objects"
        end
        payload
      end

      def precondition
        ->(arguments, context) { check(arguments: arguments, context: context).fetch("accepted") }
      end

      def check(arguments:, context:, event_id: SecureRandom.uuid)
        args = authorize!(arguments, context)
        request_digest = Knowledge.digest("arguments" => args, "gate" => digest, "identity" => Boundary.identity(context))
        source.with_snapshot(arguments: args, context: context, journal: journal) do |snapshot|
          authorize!(args, context)
          journal.once(kind: "decision", key: "#{name}:#{event_id}", request_digest: request_digest, context: context) do
            evaluate(snapshot, args, context)
          end
        end
      end

      # Internal, synchronous DB effects only. Authorize again on every replay;
      # a successful receipt prevents re-execution even after business state changes.
      def execute(arguments:, context:, operation:, idempotency_key:)
        args = authorize!(arguments, context)
        Knowledge.text(operation)
        Knowledge.text(idempotency_key)
        request_digest = Knowledge.digest("arguments" => args, "gate" => digest,
          "operation" => operation, "identity" => Boundary.identity(context))
        receipt = source.with_snapshot(arguments: args, context: context, journal: journal) do |snapshot|
          authorize!(args, context)
          journal.once(kind: "execution", key: "#{operation}:#{idempotency_key}",
                       request_digest: request_digest, context: context) do
            verdict = evaluate(snapshot, args, context)
            if verdict.fetch("accepted")
              output = yield
              if output.respond_to?(:err?) && output.err?
                raise DecisionDenied, "executor returned an error"
              end
              output = output.value if output.respond_to?(:value)
              { "status" => "executed", "verdict" => verdict, "output" => Boundary.data(output) }
            else
              { "status" => "blocked", "verdict" => verdict }
            end
          end
        end
        raise DecisionDenied, "knowledge gate did not establish required claims" unless receipt.fetch("status") == "executed"
        receipt.fetch("output")
      end

      private

      def authorize!(arguments, context)
        Boundary.identity(context)
        args = Boundary.data(arguments)
        raise InvalidContract, "arguments must be an object" unless args.is_a?(Hash)
        raise AccessDenied, "decision access denied" unless @authorize.call(args, context) == true
        args
      end

      def evaluate(snapshot, arguments, context)
        result = @engine.run(snapshot)
        checks = claims(arguments, context).map do |claim|
          query = result.query(claim.fetch("relation"), *claim.fetch("values"))
          verified = query.fetch("status") == "entailed" && ProofChecker.new.verify(
            snapshot: snapshot, relation: claim.fetch("relation"), values: claim.fetch("values"), proof: query.fetch("proof"))
          { "claim" => claim, "status" => query.fetch("status"), "verified" => verified,
            "proof" => query["proof"] }
        end
        journal.save_snapshot(snapshot, context: context)
        Knowledge.copy("gate_digest" => digest, "snapshot_digest" => snapshot.digest,
          "arguments_digest" => Knowledge.digest(arguments), "identity" => Boundary.identity(context),
          "accepted" => checks.all? { |check| check.fetch("verified") } && (!@require_complete || result.complete?),
          "closure_complete" => result.complete?, "limit_reason" => result.data["reason"], "checks" => checks)
      end
    end

    # AgentLoop verifier for a deliberately closed answer: {"claims": [...]}.
    # It cannot approve arbitrary prose by checking a single unrelated fact.
    class AnswerVerifier
      def initialize(gate:, arguments:)
        @gate, @arguments = gate, Boundary.data(arguments)
      end

      def call(request, context)
        answer = request.fetch("answer")
        answer = JSON.parse(answer, max_nesting: 16) if answer.is_a?(String)
        answer = Boundary.data(answer)
        unless answer.is_a?(Hash) && answer.keys == ["claims"] && answer["claims"] == @gate.claims(@arguments, context)
          return { accepted: false, reasons: ["claim_contract_mismatch"] }
        end
        verdict = @gate.check(arguments: @arguments, context: context)
        { accepted: verdict.fetch("accepted"), snapshot_digest: verdict.fetch("snapshot_digest"),
          gate_digest: @gate.digest, reasons: verdict.fetch("accepted") ? [] : ["claims_not_established"] }
      rescue Error, JSON::ParserError, KeyError, TypeError
        { accepted: false, reasons: ["knowledge_verification_failed"] }
      end
    end
  end
end
