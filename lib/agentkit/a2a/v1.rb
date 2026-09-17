# frozen_string_literal: true

require "base64"
require "openssl"
require "time"
require "net/http"
require "uri"

module Agentkit
  module A2A
    # A2A 1.0 adapter. The legacy JSON-RPC dispatcher remains available during
    # the 0.4 transition, but new integrations should use this API.
    module V1
      PROTOCOL_VERSION = "1.0"
      MEDIA_TYPE = "application/a2a+json"

      class ProtocolError < StandardError
        attr_reader :status, :type

        def initialize(message, status: 400, type: "invalid-request")
          @status = status
          @type = type
          super(message)
        end

        def to_h
          { type: "https://a2a-protocol.org/errors/#{type}", title: message,
            status: status, detail: message }
        end
      end

      class TaskStore
        def initialize
          @tasks = {}
          @mutex = Mutex.new
        end

        def put(task, tenant: nil)
          @mutex.synchronize { @tasks[key(task.fetch(:id), tenant)] = deep_copy(task) }
          task
        end

        def get(id, tenant: nil)
          @mutex.synchronize { deep_copy(@tasks[key(id, tenant)]) }
        end

        def list(tenant: nil)
          prefix = "#{tenant || "public"}:"
          @mutex.synchronize do
            @tasks.select { |k, _| k.start_with?(prefix) }.values.map { |t| deep_copy(t) }
          end
        end

        def reset! = @mutex.synchronize { @tasks.clear }

        private

        def key(id, tenant) = "#{tenant || "public"}:#{id}"
        def deep_copy(value) = value && Marshal.load(Marshal.dump(value))
      end

      class ActiveRecordTaskStore
        def put(task, tenant: nil)
          scope = tenant.to_s.empty? ? "__global__" : tenant.to_s
          record = Agentkit::A2aTaskRecord.find_or_initialize_by(tenant_key: scope,
                                                                 task_id: task.fetch(:id))
          record.payload = task
          record.save!
          task
        end

        def get(id, tenant: nil)
          scope = tenant.to_s.empty? ? "__global__" : tenant.to_s
          payload = Agentkit::A2aTaskRecord.find_by(tenant_key: scope,
                                                    task_id: id)&.payload
          deep_symbolize(payload) if payload
        end

        def list(tenant: nil)
          scope = tenant.to_s.empty? ? "__global__" : tenant.to_s
          Agentkit::A2aTaskRecord.where(tenant_key: scope)
            .order(created_at: :desc).map { |record| deep_symbolize(record.payload) }
        end

        # Resetting kernel ports must not delete durable protocol history.
        def reset! = nil

        private

        def deep_symbolize(value)
          case value
          when Hash then value.each_with_object({}) { |(key, item), result| result[key.to_sym] = deep_symbolize(item) }
          when Array then value.map { |item| deep_symbolize(item) }
          else value
          end
        end
      end

      class << self
        attr_writer :task_store

        def task_store = @task_store ||= TaskStore.new
        def reset! = task_store.reset!

        def resolve_context(subject = nil, tenant: nil)
          return subject if subject.is_a?(Context)

          resolver = Agentkit.config.a2a.tenant_resolver
          account = resolver&.call(subject || tenant)
          return Context.new(account: account, metadata: { via: "a2a", a2a_tenant: tenant }) if account

          Context.new(tenant_key: tenant, metadata: { via: "a2a", a2a_tenant: tenant })
        end

        def card(base_url: nil, context: nil)
          cfg = Agentkit.config.a2a
          ctx = context || Context.resolve
          base = (base_url || cfg.base_url).to_s.chomp("/")
          interface = { url: "#{base}#{cfg.mount_path}", protocolBinding: "HTTP+JSON",
                        protocolVersion: PROTOCOL_VERSION }
          interface[:tenant] = ctx.tenant_key if ctx.tenant_key

          result = {
            name: tenant_value(ctx, :name) || cfg.name || Agentkit.config.domain_name,
            description: tenant_value(ctx, :description) || cfg.description ||
              "#{Agentkit.config.domain_name} agent endpoint",
            supportedInterfaces: [interface],
            version: cfg.version,
            capabilities: { streaming: false, pushNotifications: false,
                            extendedAgentCard: false },
            securitySchemes: stringify_keys(cfg.security_schemes),
            securityRequirements: Array(cfg.security_requirements),
            defaultInputModes: ["application/json", "text/plain"],
            defaultOutputModes: ["application/json", "text/plain"],
            skills: Agentkit::A2A.exposed_capabilities(nil, ctx).map { |cap| skill_for(cap) }
          }
          result[:provider] = { organization: cfg.provider_name, url: cfg.provider_url } if cfg.provider_name && cfg.provider_url
          result[:documentationUrl] = cfg.documentation_url if cfg.documentation_url
          result = cfg.card_builder.call(result, ctx) if cfg.card_builder
          CardSigner.sign(result, context: ctx)
        end

        def skill_for(capability)
          skill = Agentkit::A2A.skill_for(capability)
          skill.delete(:parameters)
          skill.delete(:risk)
          skill.delete(:requiresHumanApproval)
          skill[:examples] = []
          skill
        end

        def send_message(payload, context: Context.resolve)
          message = fetch(payload, :message)
          raise ProtocolError, "message is required" unless message.is_a?(Hash)
          raise ProtocolError, "message.messageId is required" if fetch(message, :messageId).to_s.empty?

          metadata = fetch(message, :metadata) || fetch(payload, :metadata) || {}
          skill_id = fetch(metadata, :skillId) || fetch(metadata, :skill) || fetch(metadata, :capability)
          inputs = inputs_from(fetch(message, :parts))
          skill_id ||= inputs.delete("skill") || inputs.delete(:skill)
          if skill_id.to_s.empty? && fetch(message, :taskId)
            previous = task_store.get(fetch(message, :taskId), tenant: context.tenant_key)
            skill_id = previous&.dig(:metadata, :capability)
          end
          raise ProtocolError, "message metadata must identify skillId" if skill_id.to_s.empty?

          cap = Capability[skill_id.to_s]
          raise ProtocolError.new("unknown skill: #{skill_id}", status: 404, type: "skill-not-found") unless cap
          unless Agentkit::A2A.exposed_capabilities(nil, context).include?(cap)
            raise ProtocolError.new("skill is not available", status: 403, type: "forbidden")
          end

          missing = cap.inputs.keys - symbolize(inputs).keys
          return input_required_task(message, cap, missing, context) if missing.any?

          legacy = Agentkit::A2A.handle(
            { "jsonrpc" => "2.0", "id" => fetch(message, :messageId),
              "method" => "capabilities.invoke",
              "params" => { "capability" => cap.name.to_s, "inputs" => inputs,
                             "idempotency_key" => fetch(metadata, :idempotencyKey) } },
            context: context
          )
          raise ProtocolError, legacy.dig(:error, :message) if legacy[:error]

          task_from_result(message, cap, legacy[:result], context)
        end

        def get_task(id, context: Context.resolve)
          task = task_store.get(id, tenant: context.tenant_key) ||
            raise(ProtocolError.new("task not found", status: 404, type: "task-not-found"))
          legacy_id = task.dig(:metadata, :legacyTaskId)
          return task unless legacy_id && task.dig(:status, :state) == "TASK_STATE_AUTH_REQUIRED"

          result = Agentkit::A2A.handle(
            { "jsonrpc" => "2.0", "id" => SecureRandom.uuid, "method" => "tasks.get",
              "params" => { "taskId" => legacy_id } }, context: context
          )[:result]
          mapped = { "completed" => "TASK_STATE_COMPLETED", "rejected" => "TASK_STATE_REJECTED",
                     "failed" => "TASK_STATE_FAILED", "pending_approval" => "TASK_STATE_AUTH_REQUIRED" }
          task[:status] = status(mapped.fetch(result[:status], "TASK_STATE_WORKING")) if result
          task_store.put(task, tenant: context.tenant_key)
        end

        def list_tasks(context: Context.resolve) = task_store.list(tenant: context.tenant_key)

        def cancel_task(id, context: Context.resolve)
          task = get_task(id, context: context)
          state = task.dig(:status, :state)
          if %w[TASK_STATE_COMPLETED TASK_STATE_FAILED TASK_STATE_CANCELED TASK_STATE_REJECTED].include?(state)
            raise ProtocolError.new("task is already terminal", type: "unsupported-operation")
          end
          task[:status] = status("TASK_STATE_CANCELED")
          task_store.put(task, tenant: context.tenant_key)
        end

        private

        def task_from_result(message, cap, result, context)
          state = case result[:status]
                  when "completed" then "TASK_STATE_COMPLETED"
                  when "failed" then "TASK_STATE_FAILED"
                  when "pending_approval" then "TASK_STATE_AUTH_REQUIRED"
                  else "TASK_STATE_WORKING"
                  end
          task_id = result[:taskId] || SecureRandom.uuid
          task = { id: task_id, contextId: fetch(message, :contextId) || context.trace_id,
                   status: status(state), history: [normalize_message(message)] }
          if result.key?(:result)
            task[:artifacts] = [{ artifactId: SecureRandom.uuid, name: cap.title,
                                  parts: [{ data: result[:result] }] }]
          end
          task[:metadata] = { capability: cap.name.to_s, legacyTaskId: result[:taskId] }.compact
          task_store.put(task, tenant: context.tenant_key)
        end

        def input_required_task(message, cap, missing, context)
          reply = { role: "ROLE_AGENT", messageId: SecureRandom.uuid,
                    parts: [{ text: "Missing required inputs: #{missing.join(', ')}" }] }
          task = { id: fetch(message, :taskId) || SecureRandom.uuid,
                   contextId: fetch(message, :contextId) || context.trace_id,
                   status: status("TASK_STATE_INPUT_REQUIRED", message: reply),
                   history: [normalize_message(message), reply], metadata: { capability: cap.name.to_s } }
          task_store.put(task, tenant: context.tenant_key)
        end

        def normalize_message(message) = symbolize(message)
        def status(state, message: nil) = { state: state, timestamp: Time.now.utc.iso8601, message: message }.compact

        def inputs_from(parts)
          Array(parts).each_with_object({}) do |part, result|
            data = fetch(part, :data)
            result.merge!(data) if data.is_a?(Hash)
          end
        end

        def tenant_value(ctx, name)
          account = ctx.account
          account.public_send(name) if account&.respond_to?(name)
        end

        def fetch(hash, key) = hash&.[](key) || hash&.[](key.to_s)
        def symbolize(hash) = hash.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
        def stringify_keys(hash) = (hash || {}).each_with_object({}) { |(k, v), h| h[k.to_s] = v }
      end

      module CanonicalJSON
        module_function

        def generate(value)
          case value
          when Hash
            "{" + value.map { |k, v| [k.to_s, v] }.sort_by(&:first)
              .map { |k, v| "#{JSON.generate(k)}:#{generate(v)}" }.join(",") + "}"
          when Array then "[#{value.map { |v| generate(v) }.join(',')}]"
          else JSON.generate(value)
          end
        end
      end

      module CardSigner
        module_function

        def sign(card, context: nil)
          cfg = Agentkit.config.a2a
          source = cfg.signing_key
          source = source.call(context) if source.respond_to?(:call)
          return card unless source

          key = source.is_a?(OpenSSL::PKey::PKey) ? source : OpenSSL::PKey.read(source)
          header = { alg: cfg.signature_algorithm, typ: "JOSE", kid: cfg.signing_key_id }
          header[:jku] = cfg.signing_jwks_url if cfg.signing_jwks_url
          protected_value = encode(JSON.generate(header.compact))
          payload = encode(CanonicalJSON.generate(card.reject { |k, _| k.to_s == "signatures" }))
          signature = key.sign(OpenSSL::Digest::SHA256.new, "#{protected_value}.#{payload}")
          card.merge(signatures: [{ protected: protected_value, signature: encode(signature) }])
        end

        def verify!(card, keys: Agentkit.config.a2a.trusted_keys,
                    policy: Agentkit.config.a2a.verification)
          signatures = Array(card["signatures"] || card[:signatures])
          return true if policy == :disabled || (policy == :if_present && signatures.empty?)
          raise ProtocolError.new("unsigned Agent Card", status: 401, type: "invalid-agent-card") if signatures.empty?

          unsigned = card.reject { |k, _| k.to_s == "signatures" }
          payload = encode(CanonicalJSON.generate(unsigned))
          valid = signatures.any? do |entry|
            protected_value = entry["protected"] || entry[:protected]
            header = JSON.parse(decode(protected_value))
            source = keys[header["kid"]] || keys[header["kid"].to_sym]
            next false unless source && header["alg"] == "RS256"
            key = source.is_a?(OpenSSL::PKey::PKey) ? source : OpenSSL::PKey.read(source)
            key.verify(OpenSSL::Digest::SHA256.new, decode(entry["signature"] || entry[:signature]),
                       "#{protected_value}.#{payload}")
          rescue StandardError
            false
          end
          raise ProtocolError.new("Agent Card signature is invalid", status: 401,
                                  type: "invalid-agent-card") unless valid
          true
        end

        def encode(value) = Base64.urlsafe_encode64(value, padding: false)
        def decode(value) = Base64.urlsafe_decode64(value.to_s)
      end


      class Client
        attr_reader :base_url, :token, :timeout

        def initialize(base_url:, token: nil, timeout: 30, transport: nil,
                       verification: Agentkit.config.a2a.verification,
                       trusted_keys: Agentkit.config.a2a.trusted_keys)
          @base_url = base_url.to_s.chomp("/")
          @token = token
          @timeout = timeout
          @transport = transport
          @verification = verification
          @trusted_keys = trusted_keys
        end

        def card
          result = request(:get, "/.well-known/agent-card.json")
          CardSigner.verify!(result, keys: @trusted_keys, policy: @verification)
          result
        end

        def send_message(message, configuration: nil)
          body = { message: message }
          body[:configuration] = configuration if configuration
          request(:post, endpoint("/message:send"), body)
        end

        def task(id) = request(:get, endpoint("/tasks/#{escape(id)}"))
        def tasks = request(:get, endpoint("/tasks"))
        def cancel(id) = request(:post, endpoint("/tasks/#{escape(id)}:cancel"), {})

        private

        def endpoint(suffix) = Agentkit.config.a2a.mount_path + suffix

        def request(verb, path, body = nil)
          url = base_url + path
          return @transport.call(verb, url, body, headers) if @transport

          uri = URI(url)
          raise ProtocolError.new("HTTPS is required for remote A2A peers", status: 400,
                                  type: "insecure-peer") unless uri.is_a?(URI::HTTPS) || local?(uri.host)

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = [timeout, 10].min
          http.read_timeout = timeout
          klass = verb == :post ? Net::HTTP::Post : Net::HTTP::Get
          req = klass.new(uri)
          headers.each { |key, value| req[key] = value }
          req.body = JSON.generate(body) if body
          response = http.request(req)
          parsed = JSON.parse(response.body.to_s)
          unless response.code.to_i.between?(200, 299)
            request_id = SecureRandom.uuid
            Agentkit.logger&.error(
              "[AgentKit::A2A::V1::Client] request_id=#{request_id} " \
              "peer=#{base_url} status=#{response.code.to_i}"
            )
            raise ProtocolError.new("peer request failed (request_id=#{request_id})",
                                    status: response.code.to_i, type: "peer-error")
          end
          parsed
        rescue ProtocolError
          raise
        rescue JSON::ParserError
          request_id = SecureRandom.uuid
          Agentkit.logger&.error(
            "[AgentKit::A2A::V1::Client] request_id=#{request_id} peer=#{base_url} invalid_json=true"
          )
          raise ProtocolError.new("invalid peer response (request_id=#{request_id})",
                                  status: 502, type: "peer-error")
        rescue StandardError => e
          request_id = SecureRandom.uuid
          Agentkit.logger&.error(
            "[AgentKit::A2A::V1::Client] request_id=#{request_id} peer=#{base_url} error=#{e.class}"
          )
          raise ProtocolError.new("peer request failed (request_id=#{request_id})",
                                  status: 502, type: "peer-error")
        end

        def headers
          { "Content-Type" => MEDIA_TYPE, "Accept" => MEDIA_TYPE,
            "A2A-Version" => PROTOCOL_VERSION }.tap do |values|
            values["Authorization"] = "Bearer #{token}" if token
          end
        end

        def escape(value) = URI.encode_www_form_component(value.to_s)
        def local?(host) = %w[localhost 127.0.0.1 ::1].include?(host)
      end
    end
  end
end
