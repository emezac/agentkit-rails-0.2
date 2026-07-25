# frozen_string_literal: true

require "spec_helper"

require "active_support"
require "active_support/core_ext/class/attribute"
require "active_support/core_ext/object/blank"
require "active_support/concern"
require_relative "../../app/concerns/agentkit/triggerable"

# Regression spec for bug B5 — the quadratic trigger.
#
# v0.1's AgentTriggerable installed one AR callback per `trigger_agent`
# declaration, and every callback then looped over all declarations for that
# event. Three role bots on :update meant nine agent runs and nine LLM calls.
# Nobody caught it because the old spec only asserted on the registry array and
# never fired a callback.
RSpec.describe Agentkit::Triggerable do
  # Minimal ActiveRecord stand-in: just the callback surface the concern uses.
  let(:base_class) do
    Class.new do
      def self.callbacks = @callbacks ||= Hash.new { |h, k| h[k] = [] }

      def self.after_commit(on:, &block)
        callbacks[on] << block
      end

      def self.name = "FakeRecord"

      attr_accessor :id, :status, :saved_changes

      def initialize(id: 1, status: "new", saved_changes: {})
        @id = id
        @status = status
        @saved_changes = saved_changes
      end

      # Simulates the commit: run every callback registered for the event.
      def fire!(event)
        self.class.callbacks[event].each { |cb| instance_exec(&cb) }
      end
    end
  end

  let(:calls) { [] }

  def agent_double(name, sink)
    Class.new do
      define_singleton_method(:name) { name }
      define_singleton_method(:call) do |record, context: nil|
        sink << [name, record.respond_to?(:id) ? record.id : record]
        "ok"
      end
    end
  end

  describe "fan-out on a single event" do
    it "invokes each declared agent exactly once, not N times N" do
      sink = calls
      finance    = agent_double("FinanceBot", sink)
      accounting = agent_double("AccountingBot", sink)
      ceo        = agent_double("CeoBot", sink)

      model = Class.new(base_class) do
        include Agentkit::Triggerable
      end
      model.trigger_agent finance,    on: :update, async: false
      model.trigger_agent accounting, on: :update, async: false
      model.trigger_agent ceo,        on: :update, async: false

      model.new.fire!(:update)

      expect(sink.map(&:first)).to contain_exactly("FinanceBot", "AccountingBot", "CeoBot")
      expect(sink.size).to eq(3) # v0.1 produced 9 here
    end

    it "installs exactly one callback per event regardless of declarations" do
      model = Class.new(base_class) { include Agentkit::Triggerable }
      3.times { |i| model.trigger_agent agent_double("A#{i}", calls), on: :update, async: false }

      expect(model.callbacks[:update].size).to eq(1)
    end

    it "ignores a duplicate declaration instead of doubling it" do
      sink  = calls
      agent = agent_double("Solo", sink)
      model = Class.new(base_class) { include Agentkit::Triggerable }

      model.trigger_agent agent, on: :create, async: false
      model.trigger_agent agent, on: :create, async: false

      model.new.fire!(:create)
      expect(sink.size).to eq(1)
    end
  end

  describe "guards" do
    it "honours if:, unless: and only_if_changed:" do
      sink  = calls
      agent = agent_double("Guarded", sink)
      model = Class.new(base_class) { include Agentkit::Triggerable }
      model.trigger_agent agent, on: :update, async: false,
                                 only_if_changed: [:status],
                                 if: ->(r) { r.status == "atrasada" }

      model.new(status: "atrasada", saved_changes: { "total" => [1, 2] }).fire!(:update)
      expect(sink).to be_empty # status did not change

      model.new(status: "ok", saved_changes: { "status" => %w[a b] }).fire!(:update)
      expect(sink).to be_empty # guard is false

      model.new(status: "atrasada", saved_changes: { "status" => %w[a b] }).fire!(:update)
      expect(sink.size).to eq(1)
    end
  end

  describe "failure isolation" do
    it "never lets a trigger break the domain transaction" do
      exploding = Class.new do
        def self.name = "Exploding"
        def self.call(*, **) = raise("agent blew up")
      end
      model = Class.new(base_class) { include Agentkit::Triggerable }
      model.trigger_agent exploding, on: :create, async: false

      expect { model.new.fire!(:create) }.not_to raise_error
      expect(emitted("trigger.failed")).not_to be_empty
    end
  end

  describe "telemetry" do
    it "emits one trigger.fire per dispatch" do
      model = Class.new(base_class) { include Agentkit::Triggerable }
      model.trigger_agent agent_double("Bot", calls), on: :create, async: false

      model.new.fire!(:create)

      events = emitted("trigger.fire")
      expect(events.size).to eq(1)
      expect(events.first.dims[:target]).to eq("Bot")
    end
  end
end
