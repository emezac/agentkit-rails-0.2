# frozen_string_literal: true

module Agentkit
  # An opt-in, durable admission boundary for asynchronous Flow delegations.
  # The host authenticates the requester and supplies a policy callback in every
  # process that can run a worker. Model text cannot issue or widen a mandate.
  class TaskMandate
    MAX_FIELD = 256
    class << self
      attr_accessor :authorizer

      def issue(flow:, source:, resource:, thread:, policy_version:, context:, allowed_tools: [])
        raise ConfigurationError, "mandate requires a scoped principal" if context.principal.to_s.empty? || context.tenant_key.to_s.empty?
        unless allowed_tools.is_a?(Array) && allowed_tools.size <= 64
          raise ArgumentError, "mandate allows at most 64 tools"
        end
        tools = allowed_tools.map { |name| safe!(name).freeze }.uniq.sort.freeze
        data = {
          "flow" => safe!(flow), "source" => safe!(source), "resource" => safe!(resource),
          "thread" => safe!(thread), "requester" => safe!(context.principal),
          "tenant_key" => safe!(context.tenant_key), "account_id" => id_of(context.account),
          "policy_version" => safe!(policy_version), "allowed_tools" => tools,
          "issued_at" => Time.now.utc.iso8601(6)
        }
        raise PolicyDenied, "mandate admission denied" unless authorized?(data, "issue", context)
        data["digest"] = digest(data)
        data.each_value(&:freeze)
        new(data)
      end

      def guard_run!(run, phase: "resume")
        data = mandate_data(run)
        return true unless data
        verify_digest!(data)
        raise PolicyDenied, "mandate flow changed" unless data["flow"] == run.flow_name
        raise PolicyDenied, "mandate tenant changed" unless data["tenant_key"] == run.tenant_key
        raise PolicyDenied, "mandate account changed" unless data["account_id"] == run.account_id

        ctx = Context.new(tenant_key: run.tenant_key, account: run.account_id,
          principal: data["requester"], metadata: { task_mandate: data })
        raise PolicyDenied, "mandate no longer authorized" unless authorized?(data, phase, ctx)
        true
      end

      def mandate_data(run)
        metadata = run.context.is_a?(Hash) ? (run.context["metadata"] || run.context[:metadata]) : nil
        data = metadata.is_a?(Hash) ? (metadata["task_mandate"] || metadata[:task_mandate]) : nil
        return nil unless data
        raise PolicyDenied, "invalid stored mandate" unless data.is_a?(Hash)
        data.transform_keys(&:to_s)
      end

      def guard_tool!(context, name)
        metadata = context.metadata
        data = metadata["task_mandate"] || metadata[:task_mandate]
        return true unless data
        raise ToolExecutionDenied, "invalid task mandate" unless data.is_a?(Hash)
        data = data.transform_keys(&:to_s)
        begin
          verify_digest!(data)
          raise PolicyDenied, "mandate tenant changed" unless data["tenant_key"] == context.tenant_key
          raise PolicyDenied, "tool outside task mandate" unless data.fetch("allowed_tools").include?(name.to_s)
          raise PolicyDenied, "mandate no longer authorized" unless authorized?(data, "tool:#{name}", context)
        rescue PolicyDenied, KeyError
          raise ToolExecutionDenied, "tool outside task mandate"
        end
        true
      end

      private

      def new(data)
        super(data.freeze)
      end

      def safe!(value)
        text = value.to_s
        raise ArgumentError, "mandate field must contain 1..#{MAX_FIELD} bytes" unless
          text.bytesize.between?(1, MAX_FIELD) && !text.match?(/[[:cntrl:]]/)
        text
      end

      def id_of(value) = value.respond_to?(:id) ? value.id : value
      def authorized?(data, phase, context)
        authorizer&.call(data, phase, context) == true
      rescue StandardError
        false
      end
      def digest(data) = Digest::SHA256.hexdigest(JSON.generate(data.sort.to_h))
      def verify_digest!(data)
        raise PolicyDenied, "stored mandate changed" unless data["digest"] == digest(data.except("digest"))
      end
    end

    def initialize(data) = @data = data
    def to_h = @data.dup
    def flow = @data.fetch("flow")
    def requester = @data.fetch("requester")
    def tenant_key = @data.fetch("tenant_key")
    def account_id = @data.fetch("account_id")
  end
end
