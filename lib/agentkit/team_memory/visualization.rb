# frozen_string_literal: true

require "json"
require "securerandom"

module Agentkit
  module TeamMemory
    # Ephemeral publication layer for already-computed activation traces.
    # It cannot mutate snapshots, scores or authorization decisions.
    module Visualization
      Entry = Struct.new(:trace, :tenant_key, :principal_digest, :expires_at, keyword_init: true)

      class << self
        def publish(trace, context: Context.resolve, ttl: 900)
          unless trace.is_a?(SpreadingActivation::ActivationTrace)
            raise ConfigurationError, "visualization accepts ActivationTrace only"
          end
          payload = JSON.generate(trace.to_h)
          limit = Agentkit.config.team_memory.graph_trace_max_bytes.to_i
          raise ConfigurationError, "activation trace exceeds payload limit" if payload.bytesize > limit

          id = SecureRandom.hex(16)
          mutex.synchronize do
            prune!
            entries[id] = Entry.new(trace: trace, tenant_key: tenant(context),
                                    principal_digest: principal_digest(context),
                                    expires_at: Time.now + [[ttl.to_i, 1].max, 3_600].min)
          end
          id
        end

        def fetch(id, context: Context.resolve)
          mutex.synchronize do
            prune!
            entry = entries[id.to_s]
            return nil unless entry && entry.tenant_key == tenant(context) &&
                              entry.principal_digest == principal_digest(context)

            entry.trace
          end
        end

        def reset!
          mutex.synchronize { @entries = {} }
        end

        private

        def entries = @entries ||= {}
        def mutex = @mutex ||= Mutex.new
        def tenant(context) = (context.tenant_key || TeamMemory::GLOBAL_TENANT_KEY).to_s

        def principal_digest(context)
          principal = context.principal || context.user
          id = principal.respond_to?(:id) ? principal.id : principal
          Graph.digest_for(tenant: tenant(context), principal: id)
        end

        def prune!
          now = Time.now
          entries.delete_if { |_id, entry| entry.expires_at <= now }
        end
      end
    end
  end
end
