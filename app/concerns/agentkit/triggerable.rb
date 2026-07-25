# frozen_string_literal: true

module Agentkit
  # Declarative agent/flow triggers on ActiveRecord lifecycle events.
  #
  # Three bugs from v0.1's AgentTriggerable are fixed here:
  #
  #   B5 — quadratic execution. The old DSL registered ONE callback per
  #        `trigger_agent` declaration, and each callback then looped over
  #        *every* trigger for that event. Three role bots on `:update` meant
  #        3 callbacks × 3 triggers = 9 agent runs and 9 LLM calls. Here a
  #        single callback per (class, event) is installed once and iterates
  #        the declarations exactly once.
  #
  #   B8 — `on: :destroy, async: true` never worked: the job did
  #        `record_class.find(record_id)` on a row that no longer existed and
  #        silently swallowed RecordNotFound. Destroy triggers now carry a
  #        serialized snapshot instead of an id.
  #
  #   Race — callbacks fired on `after_save`, so an async agent could read a
  #        record that had not been committed. Everything is `after_commit`.
  #
  #   class Factura < ApplicationRecord
  #     include Agentkit::Triggerable
  #
  #     trigger_flow  OverdueInvoiceCouncilFlow, on: :update,
  #                   only_if_changed: [:status], if: ->(r) { r.status == "atrasada" }
  #     trigger_agent PaymentMonitorAgent, on: :create, async: false
  #   end
  module Triggerable
    extend ActiveSupport::Concern

    included do
      class_attribute :_agentkit_triggers, instance_writer: false, default: []
      class_attribute :_agentkit_installed_events, instance_writer: false, default: []
    end

    class_methods do
      def trigger_agent(agent_class, on:, **opts)
        register_trigger(kind: :agent, target: agent_class, event: on, **opts)
      end

      def trigger_flow(flow_class, on:, **opts)
        register_trigger(kind: :flow, target: flow_class, event: on, **opts)
      end

      def register_trigger(kind:, target:, event:, async: true, if: nil, unless: nil,
                           only_if_changed: nil, debounce: nil, input: nil)
        binding_ref = binding
        declaration = {
          kind: kind, target: target, event: event.to_sym, async: async,
          guard: binding_ref.local_variable_get(:if),
          unless_guard: binding_ref.local_variable_get(:unless),
          only_if_changed: Array(only_if_changed).map(&:to_s).presence,
          debounce: debounce, input: input
        }

        # Duplicate declarations are ignored rather than doubled.
        return if _agentkit_triggers.any? { |t| t.slice(:kind, :target, :event) == declaration.slice(:kind, :target, :event) }

        self._agentkit_triggers = _agentkit_triggers + [declaration]
        install_callback(event.to_sym)
      end

      # Exactly one callback per event per class, installed on first use.
      def install_callback(event)
        return if _agentkit_installed_events.include?(event)

        self._agentkit_installed_events = _agentkit_installed_events + [event]

        case event
        when :create  then after_commit(on: :create)  { agentkit_fire_triggers(:create) }
        when :update  then after_commit(on: :update)  { agentkit_fire_triggers(:update) }
        when :destroy then after_commit(on: :destroy) { agentkit_fire_triggers(:destroy) }
        else raise ArgumentError, "trigger event must be :create, :update or :destroy"
        end
      end
    end

    # ─── Instance ────────────────────────────────────────────────────────────

    def agentkit_fire_triggers(event)
      self.class._agentkit_triggers.each do |trigger|
        next unless trigger[:event] == event
        next unless agentkit_changed_enough?(trigger)
        next unless agentkit_passes_guard?(trigger)
        next if agentkit_debounced?(trigger)

        agentkit_dispatch(trigger, event)
      end
    rescue StandardError => e
      # A trigger must never roll back the domain transaction it observes.
      Agentkit.logger&.error("[AgentKit::Triggerable] #{self.class.name}##{id}: #{e.message}")
      Agentkit::Telemetry.emit("trigger.failed",
                               dims: { model: self.class.name, event: event, error_class: e.class.name })
    end

    private

    def agentkit_dispatch(trigger, event)
      Agentkit::Telemetry.emit("trigger.fire",
                               dims: { model: self.class.name, event: event,
                                       target: trigger[:target].name, async: trigger[:async] })

      context = Agentkit::Context.new(user: agentkit_triggering_user, account: agentkit_triggering_account)
      payload = trigger[:input] ? instance_exec(&trigger[:input]) : self

      if trigger[:async] && defined?(Agentkit::TriggerJob)
        Agentkit::TriggerJob.perform_later(
          trigger[:kind].to_s, trigger[:target].name, self.class.name,
          # Destroy has no row left to load, so the snapshot travels instead.
          event == :destroy ? nil : id,
          event == :destroy ? attributes : nil,
          agentkit_triggering_user&.id
        )
      elsif trigger[:kind] == :flow
        trigger[:target].call(context: context, record: payload)
      else
        trigger[:target].call(payload, context: context)
      end
    end

    def agentkit_changed_enough?(trigger)
      return true if trigger[:only_if_changed].nil?
      return true unless respond_to?(:saved_changes)

      (saved_changes.keys & trigger[:only_if_changed]).any?
    end

    def agentkit_passes_guard?(trigger)
      ok = agentkit_eval_guard(trigger[:guard], default: true)
      ok && !agentkit_eval_guard(trigger[:unless_guard], default: false)
    end

    def agentkit_eval_guard(guard, default:)
      return default if guard.nil?
      return send(guard) if guard.is_a?(Symbol)
      return guard.arity.zero? ? instance_exec(&guard) : guard.call(self) if guard.respond_to?(:call)

      default
    end

    # Simple per-record debounce so a burst of updates fires once.
    def agentkit_debounced?(trigger)
      window = trigger[:debounce]
      return false if window.nil?

      key = "agentkit:debounce:#{self.class.name}:#{id}:#{trigger[:target].name}"
      store = Agentkit::Triggerable.debounce_store
      last = store[key]
      return true if last && (Time.now - last) < window

      store[key] = Time.now
      false
    end

    # Override in the domain model when the agent needs a specific actor.
    def agentkit_triggering_user
      respond_to?(:user) ? user : nil
    end

    def agentkit_triggering_account
      return account if respond_to?(:account)
      return company&.account if respond_to?(:company) && company.respond_to?(:account)

      nil
    end

    def self.debounce_store
      @debounce_store ||= {}
    end
  end

  # v0.1 name kept so existing `include Agentkit::AgentTriggerable` compiles.
  AgentTriggerable = Triggerable
end
