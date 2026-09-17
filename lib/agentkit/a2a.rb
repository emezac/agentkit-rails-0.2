# frozen_string_literal: true

module Agentkit
  # Agent-to-Agent protocol.
  #
  # v0.1 shipped an A2aController that nobody used: `tres`, `totallook` and
  # `maas` each wrote their own from scratch. The reason is structural — the
  # kernel's version advertised a fixed list of "agent cards" that had nothing
  # to do with what the application could actually do, so it was always wrong.
  #
  # Here the card is **generated from the Capability registry**. Whatever the
  # app can do for its own chat is exactly what it exposes over A2A, with the
  # same preconditions, the same risk classification and the same HITL gate.
  # An irreversible capability cannot be triggered remotely without a human.
  #
  # Transport follows what `tres` proved out: JSON-RPC 2.0 over HTTP with an
  # `X-A2A-Key` header compared in constant time, and a discovery document at
  # `/.well-known/agent.json`.
  module A2A
    PROTOCOL_VERSION = "0.2"

    # JSON-RPC 2.0 error codes, plus the A2A-specific range used by `tres`.
    ERRORS = {
      parse_error:      -32_700,
      invalid_request:  -32_600,
      method_not_found: -32_601,
      invalid_params:   -32_602,
      internal_error:   -32_603,
      unauthorized:     -32_002,
      forbidden:        -32_003,
      precondition:     -32_004,
      quota_exceeded:   -32_005,
      needs_approval:   -32_010   # not an error: the call is parked in HITL
    }.freeze

    Error = Struct.new(:code, :message, :data, keyword_init: true) do
      def to_h = { code: code, message: message, data: data }.compact
    end

    class << self
      # ─── Discovery ───────────────────────────────────────────────────────────

      # The document served at /.well-known/agent.json — derived, never hand-written.
      def card(base_url: nil, setup: nil, context: nil)
        cfg   = Agentkit.config
        ctx   = context || Context.resolve
        base  = base_url || cfg.a2a.base_url
        setup ||= Setup.current

        {
          name:             cfg.a2a.name || cfg.domain_name,
          description:      cfg.a2a.description || "#{cfg.domain_name} agent endpoint",
          protocol:         "A2A",
          protocolVersion:  PROTOCOL_VERSION,
          version:          cfg.a2a.version,
          url:              "#{base}#{cfg.a2a.mount_path}/rpc",
          documentationUrl: "#{base}#{cfg.a2a.mount_path}",
          authentication:   { schemes: ["X-A2A-Key"] },
          capabilities:     { streaming: false, pushNotifications: false,
                              stateTransitionHistory: true },
          defaultInputModes:  %w[application/json],
          defaultOutputModes: %w[application/json],
          skills: exposed_capabilities(setup, ctx).map { |c| skill_for(c) }
        }
      end

      # Only capabilities the operator marked as exposed AND whose preconditions
      # currently hold. A remote peer never sees an action it cannot invoke.
      def exposed_capabilities(setup = nil, context = nil)
        setup ||= Setup.current || Setup.build
        allow = Agentkit.config.a2a.expose

        Capability.all.select do |cap|
          next false if allow.is_a?(Array) && !allow.map(&:to_sym).include?(cap.name)
          next false if Array(Agentkit.config.a2a.hide).map(&:to_sym).include?(cap.name)

          cap.eligible?(setup, context)
        end
      end

      def skill_for(capability)
        {
          id:          capability.name.to_s,
          name:        capability.title,
          description: capability.description,
          tags:        capability.tags.map(&:to_s),
          inputModes:  %w[application/json],
          outputModes: %w[application/json],
          parameters:  capability.inputs.transform_values { |t| { type: t.to_s } },
          # Peers need to know what will happen before they call.
          risk:        capability.risk.to_s,
          requiresHumanApproval: requires_approval?(capability)
        }
      end

      def requires_approval?(capability)
        return true if capability.irreversible?
        return false if capability.auto?

        Agentkit.config.hitl.level == :strict || capability.hitl == :propose
      end

      # ─── Authentication ──────────────────────────────────────────────────────

      # Resolves a presented key into a Context. Constant-time comparison, and a
      # pluggable resolver so multi-tenant hosts can map key → account.
      def authenticate(presented_key)
        return nil if presented_key.to_s.empty?

        resolver = Agentkit.config.a2a.key_resolver
        if resolver
          account = resolver.call(presented_key.to_s)
          return nil if account.nil?

          return Context.new(account: account, metadata: { via: "a2a" })
        end

        expected = Agentkit.config.a2a.secret_key.to_s
        return nil if expected.empty?
        return nil unless secure_compare(presented_key.to_s, expected)

        Context.new(metadata: { via: "a2a" })
      end

      def secure_compare(a, b)
        return false unless a.bytesize == b.bytesize

        res = 0
        a.bytes.zip(b.bytes) { |x, y| res |= x ^ y }
        res.zero?
      end

      # ─── Server ──────────────────────────────────────────────────────────────

      # Handles one JSON-RPC envelope. Returns a hash ready to render.
      #
      #   { "jsonrpc": "2.0", "id": "1", "method": "capabilities.invoke",
      #     "params": { "capability": "import_contacts", "inputs": {...} } }
      def handle(envelope, key: nil, context: nil)
        id = envelope.is_a?(Hash) ? envelope["id"] : nil
        return rpc_error(id, :invalid_request, "envelope must be a JSON object") unless envelope.is_a?(Hash)

        method = envelope["method"].to_s
        params = envelope["params"] || {}

        ctx = context || authenticate(key)
        return rpc_error(id, :unauthorized, "invalid or missing X-A2A-Key") if ctx.nil? && !public_method?(method)

        handler = Server::METHODS[method]
        return rpc_error(id, :method_not_found, "unknown method: #{method}") if handler.nil?

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result  = Agentkit.with_context(ctx || Context.new) { Server.public_send(handler, params) }
        emit(method, ctx, started, "ok")

        result.is_a?(Error) ? rpc_error(id, result.code, result.message, result.data) : rpc_result(id, result)
      rescue StandardError => e
        request_id = SecureRandom.uuid
        Agentkit.logger&.error("[AgentKit::A2A] request_id=#{request_id} error=#{e.class}")
        emit(method, context, nil, "error")
        rpc_error(id, :internal_error, "internal error", { requestId: request_id })
      end

      def public_method?(method) = %w[agent.card].include?(method)

      def rpc_result(id, result)
        { jsonrpc: "2.0", id: id, result: result }
      end

      def rpc_error(id, code, message, data = nil)
        numeric = code.is_a?(Symbol) ? ERRORS.fetch(code, ERRORS[:internal_error]) : code
        { jsonrpc: "2.0", id: id, error: { code: numeric, message: message, data: data }.compact }
      end

      # HTTP status for a JSON-RPC error, so proxies and clients behave sanely.
      def http_status_for(response)
        return 200 unless response[:error]

        case response.dig(:error, :code)
        when ERRORS[:unauthorized]   then 401
        when ERRORS[:forbidden]      then 403
        when ERRORS[:method_not_found] then 404
        when ERRORS[:quota_exceeded] then 429
        when ERRORS[:internal_error] then 500
        else 200   # application-level errors still carry a 200 in JSON-RPC
        end
      end

      private

      def emit(method, ctx, started, status)
        Telemetry.emit("a2a.request",
                       dims: { method: method, status: status, tenant: ctx&.tenant_key },
                       measures: { duration_ms: started ? ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round : 0 })
        Audit.record(event_type: "a2a.#{method}", agent_name: "A2A",
                     status: status, payload: { method: method }, context: ctx)
      end
    end

    # ─── Method handlers ───────────────────────────────────────────────────────

    module Server
      METHODS = {
        "agent.card"           => :agent_card,
        "capabilities.list"    => :capabilities_list,
        "capabilities.invoke"  => :capabilities_invoke,
        "tasks.get"            => :tasks_get,
        "proposals.list"       => :proposals_list,
        "memory.recall"        => :memory_recall
      }.freeze

      class << self
        def agent_card(_params) = A2A.card

        def capabilities_list(_params)
          { capabilities: A2A.exposed_capabilities.map { |c| A2A.skill_for(c) } }
        end

        # The heart of it: a remote invocation lands on the same rail as a local
        # proposal — Capability → Flow → HITL → audit. There is no bypass.
        def capabilities_invoke(params)
          name = params["capability"] || params["skill"] || params["name"]
          cap  = Capability[name.to_s] if name

          return Error.new(code: :invalid_params, message: "unknown capability: #{name}") if cap.nil?
          return Error.new(code: :forbidden, message: "capability not exposed over A2A") unless A2A.exposed_capabilities.include?(cap)

          inputs = symbolize(params["inputs"] || params["params"] || {})
          missing = cap.inputs.keys - inputs.keys
          return Error.new(code: :invalid_params, message: "missing inputs: #{missing.join(', ')}") if missing.any?

          unless cap.eligible?(Setup.current || Setup.build, Context.current)
            return Error.new(code: :precondition, message: "preconditions not met for #{name}")
          end

          # Irreversible or strict-gated work is parked as a suggestion and the
          # caller is handed a task id to poll — never executed silently.
          if A2A.requires_approval?(cap)
            digest = HITL.send(:canonical_digest, inputs)
            requester = Context.current&.principal || Context.current&.metadata&.dig(:principal) || "peer:a2a"
            suggestion = HITL.suggest!(
              type: "a2a:#{cap.name}", title: "A2A request: #{cap.title}",
              description: "Remote peer requested `#{cap.name}`.",
              priority: cap.irreversible? ? "high" : "medium",
              source_agent: "A2A", payload: inputs.merge("via" => "a2a"),
              idempotency_key: params["idempotency_key"],
              operation_namespace: "a2a.capability:#{cap.name}",
              metadata: { "arguments_digest" => digest, "requester_principal" => requester.to_s,
                          "force_sync" => !!params["force_sync"] }
            )
            install_hitl_handler!(suggestion.suggestion_type)
            return { status: "pending_approval", taskId: "suggestion:#{suggestion.id}",
                     capability: cap.name.to_s, risk: cap.risk.to_s }
          end

          result = cap.execute(inputs, context: Context.current)
          {
            status: result.respond_to?(:ok?) && !result.ok? ? "failed" : "completed",
            capability: cap.name.to_s,
            taskId: task_id_for(result),
            result: serialize(result)
          }
        end

        # Poll a parked approval or a long-running flow.
        def tasks_get(params)
          id = params["taskId"].to_s
          kind, ref = id.split(":", 2)

          case kind
          when "suggestion"
            s = HITL.find(ref.to_i, scope: Scope.resolve)
            return Error.new(code: :invalid_params, message: "unknown task") if s.nil?

            { taskId: id, status: task_status(s), capability: s.suggestion_type.sub("a2a:", ""),
              resolvedAt: s.resolved_at }
          when "run"
            run = Flow.shared_store.find_run_by_uuid(ref)
            return Error.new(code: :invalid_params, message: "unknown task") if run.nil?

            { taskId: id, status: run.status, steps: run.steps.map(&:to_h) }
          else
            Error.new(code: :invalid_params, message: "malformed taskId")
          end
        end

        def proposals_list(params)
          setup = Setup.current || Setup.build
          list  = Proposals.generate(setup: setup, surface: :a2a,
                                     max: (params["limit"] || 3).to_i)
          { proposals: list.map(&:to_h) }
        end

        # Off by default: exposing memory to peers is an explicit decision, and
        # imagined scenarios are never included.
        def memory_recall(params)
          return Error.new(code: :forbidden, message: "memory.recall is not exposed") unless Agentkit.config.a2a.expose_memory

          results = Memory.recall(params["query"].to_s,
                                  k: (params["k"] || 5).to_i,
                                  mode: params["mode"]&.to_sym)
          { memories: results.map { |m| { id: m.id, content: m.content, type: m.memory_type,
                                          confidence: m.confidence, ontological: m.ontological_type } } }
        end

        # Installed by both request handling and the durable execution job, so
        # an approval queued before a process restart still resolves its
        # capability at execution time instead of depending on a captured Proc.
        def install_hitl_handler!(suggestion_type)
          name = suggestion_type.to_s.delete_prefix("a2a:")
          return unless suggestion_type.to_s.start_with?("a2a:")

          capability = Capability[name]
          return unless capability

          HITL.on(suggestion_type, key: "a2a:#{name}") do |approved|
            execute_approved!(approved)
          end
        end

        def execute_approved!(approved)
          name = approved.suggestion_type.to_s.delete_prefix("a2a:")
          capability = Capability[name]
          raise CapabilityError, "approved capability is no longer registered" unless capability

          unless A2A.requires_approval?(capability) &&
                 capability.eligible?(Setup.current || Setup.build, Context.current)
            raise CapabilityError, "approved capability policy or precondition changed"
          end

          exact_inputs = approved.payload.reject { |key, _| key.to_s == "via" }
          Audit.record(
            event_type: "a2a.capability.execution_authorized",
            agent_name: "A2A",
            status: "approved",
            payload: {
              capability: name,
              arguments_digest: approved.metadata&.dig("arguments_digest"),
              suggestion_id: approved.id
            },
            context: Context.current,
            failure_mode: :required
          )
          result = capability.execute(symbolize(exact_inputs), context: Context.current)
          if result.respond_to?(:err?) && result.err?
            raise(result.error.is_a?(Exception) ? result.error : CapabilityError.new(result.error.to_s))
          end

          result
        end

        private

        def task_status(suggestion)
          case suggestion.status.to_s
          when "pending", "snoozed" then "pending_approval"
          when "approved" then "approved"
          when "executing" then "working"
          when "executed", "accepted", "auto_applied" then "completed"
          when "execution_failed", "execution_unknown" then "failed"
          when "rejected" then "rejected"
          else suggestion.status.to_s
          end
        end

        def task_id_for(result)
          run = result.respond_to?(:run) ? result.run : nil
          run ? "run:#{run.run_id}" : nil
        end

        def serialize(result)
          return result unless result.respond_to?(:ok?)
          return { error: result.error.to_s } if result.err?

          value = result.value
          case value
          when Numeric, String, TrueClass, FalseClass, NilClass, Array, Hash then value
          else value.respond_to?(:id) ? { type: value.class.name, id: value.id } : value.to_s
          end
        end

        def symbolize(hash)
          return {} unless hash.is_a?(Hash)

          hash.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
        end
      end
    end

    # ─── Outbound client ───────────────────────────────────────────────────────

    # Calling *other* agents. `tres` needed this for its orchestrator; without
    # it in the kernel, federation is one-directional.
    class Client
      attr_reader :base_url, :key, :timeout

      def initialize(base_url:, key: nil, timeout: 30, transport: nil)
        @base_url  = base_url.to_s.chomp("/")
        @key       = key
        @timeout   = timeout
        @transport = transport   # injectable for tests
      end

      def card
        get("/.well-known/agent.json")
      end

      def capabilities
        invoke("capabilities.list")["result"]&.dig("capabilities") || []
      end

      def invoke(method, params = {}, id: nil)
        envelope = { "jsonrpc" => "2.0", "id" => id || SecureRandom.uuid,
                     "method" => method, "params" => params }
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = post(rpc_path, envelope)
        Telemetry.emit("a2a.outbound",
                       dims: { method: method, peer: base_url,
                               status: response["error"] ? "error" : "ok" },
                       measures: { duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round })
        response
      end

      # Convenience: invoke and wait for a parked approval to resolve.
      def call_capability(name, inputs = {}, poll: false, interval: 5, max_wait: 300)
        response = invoke("capabilities.invoke", { "capability" => name.to_s, "inputs" => inputs })
        result   = response["result"]
        return response if result.nil? || !poll || result["status"] != "pending_approval"

        deadline = Time.now + max_wait
        while Time.now < deadline
          sleep(interval)
          status = invoke("tasks.get", { "taskId" => result["taskId"] })["result"]
          return status unless status && status["status"] == "pending_approval"
        end
        { "error" => { "code" => ERRORS[:internal_error], "message" => "timed out waiting for approval" } }
      end

      private

      def rpc_path = Agentkit.config.a2a.mount_path + "/rpc"

      def post(path, body)
        return @transport.call(:post, base_url + path, body, headers) if @transport

        http_json(:post, base_url + path, body)
      rescue StandardError => e
        failure_response(e)
      end

      def get(path)
        return @transport.call(:get, base_url + path, nil, headers) if @transport

        http_json(:get, base_url + path, nil)
      rescue StandardError => e
        failure_response(e)
      end

      def headers
        { "Content-Type" => "application/json" }.tap { |h| h["X-A2A-Key"] = key if key }
      end

      def http_json(verb, url, body)
        require "net/http"
        uri = URI(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.read_timeout = timeout

        request = verb == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
        headers.each { |k, v| request[k] = v }
        request.body = JSON.generate(body) if body

        response = http.request(request)
        JSON.parse(response.body.to_s)
      rescue StandardError => e
        failure_response(e)
      end

      def failure_response(error)
        request_id = SecureRandom.uuid
        Agentkit.logger&.error(
          "[AgentKit::A2A::Client] request_id=#{request_id} peer=#{base_url} error=#{error.class}"
        )
        { "error" => { "code" => ERRORS[:internal_error], "message" => "request failed",
                       "data" => { "requestId" => request_id } } }
      end
    end
  end
end
