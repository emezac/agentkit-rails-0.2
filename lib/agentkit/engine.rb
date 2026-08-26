# frozen_string_literal: true

require "rails/engine"

module Agentkit
  # Rails integration. The kernel works without it; this plugs the
  # ActiveRecord-backed adapters into the same ports and wires the jobs.
  class Engine < ::Rails::Engine
    isolate_namespace Agentkit

    config.agentkit = Agentkit.config

    initializer "agentkit.autoload", before: :set_autoload_paths do |app|
      app.config.autoload_paths += Dir[root.join("app", "concerns")]
    end

    # Pin our own inflection instead of inheriting the host app's.
    #
    # Zeitwerk camelizes a2a_controller.rb to A2aController by default, but an
    # app that declares `inflect.acronym "A2A"` — an entirely natural thing for
    # an app built on this gem to do — changes that globally, and then the gem's
    # own file no longer defines the constant Zeitwerk expects. Eager loading
    # fails and the host cannot boot in production.
    #
    # Naming it here makes the constant deterministic either way.
    initializer "agentkit.inflections", before: :set_autoload_paths do
      Rails.autoloaders.each do |autoloader|
        autoloader.inflector.inflect("a2a_controller" => "A2AController")
      end
    end

    # Storage ports switch to ActiveRecord once the app's models are available.
    initializer "agentkit.stores", after: :active_record do
      ActiveSupport.on_load(:active_record) do
        Agentkit::Memory.reset!
        Agentkit::Flow.shared_store = nil
        Agentkit::Flow.dispatcher   = nil

        # Without this, pending approvals live in a process-local Hash: they
        # vanish on restart and two web workers disagree about what is pending.
        if defined?(Agentkit::SuggestionRecord)
          Agentkit::HITL.store  = Agentkit::HITL::Stores::ActiveRecordStore.new
          Agentkit::HITL.ledger = Agentkit::HITL::Stores::ActiveRecordLedger.new
        end
        if defined?(Agentkit::A2aTaskRecord) && Agentkit::A2aTaskRecord.table_exists?
          Agentkit::A2A::V1.task_store = Agentkit::A2A::V1::ActiveRecordTaskStore.new
        end
      end
    end

    # v0.1 called `AutoApplySuggestionJob.perform_in`, a Sidekiq method that
    # does not exist in ActiveJob — it raised in every project. The scheduler is
    # a port now, and this is the ActiveJob implementation of it.
    initializer "agentkit.hitl_scheduler" do
      config.to_prepare do
        Agentkit::HITL.scheduler = lambda do |delay, suggestion_id, scope|
          Agentkit::AutoApplySuggestionJob.set(wait: delay).perform_later(suggestion_id, scope)
        end

        # An approval resumes the suspended run instead of ending the process.
        Agentkit::HITL.on_gate_resolved do |suggestion|
          run_id = suggestion.payload["run_id"] || suggestion.payload[:run_id]
          flow   = suggestion.payload["flow"] || suggestion.payload[:flow]
          next if run_id.blank? || flow.blank?

          Agentkit::FlowResumeJob.perform_later(flow, run_id,
                                                { tenant_key: suggestion.tenant_key,
                                                  account_id: suggestion.account_id }.compact)
        end
      end
    end

    # Live HITL inbox. The kernel emits lifecycle events and knows nothing about
    # Turbo; the engine turns them into stream broadcasts.
    initializer "agentkit.turbo_broadcast" do
      config.to_prepare do
        next unless defined?(::Turbo::StreamsChannel)

        Agentkit::HITL.observe do |event, suggestion|
          stream = ["agentkit_suggestions", suggestion.tenant_key].compact.join("_")
          case event
          when :created
            next unless suggestion.pending?

            # Turbo's channel renderer otherwise falls back to the host
            # ApplicationController. In a mounted engine that renderer does
            # not know approve_suggestion_path/reject_suggestion_path, so every
            # HITL creation logs an observer failure. Render through the
            # engine controller first, preserving the /agentkit mount prefix,
            # and broadcast the finished HTML.
            html = Agentkit::ApplicationController.render(
              partial: "agentkit/suggestions/suggestion",
              locals: {
                suggestion: suggestion,
                codes: Agentkit.config.hitl.rejection_codes
              }
            )
            ::Turbo::StreamsChannel.broadcast_prepend_to(
              stream, target: "agentkit-suggestions",
              html: html
            )
          when :resolved
            ::Turbo::StreamsChannel.broadcast_remove_to(stream, target: "suggestion_#{suggestion.id}")
          end
        end
      end
    end

    # A2A discovery at the conventional location, when enabled. Peers look for
    # /.well-known/agent.json, not for an engine-mounted path.
    initializer "agentkit.a2a_well_known" do
      config.after_initialize do
        next unless Agentkit.config.a2a.enabled

        # Load through the engine's pinned A2A inflection before host routes
        # attempt to constantize the controller with the host inflector.
        Agentkit::A2AController

        Rails.application.routes.prepend do
          get "/.well-known/agent-card.json", to: "agentkit/a2a#card", as: :agentkit_well_known_agent_card
          if Agentkit.config.a2a.legacy
            get "/.well-known/agent.json", to: "agentkit/a2a#legacy_card", as: :agentkit_well_known_agent
          end
        end
      end
    end

    # Telemetry is buffered; without a periodic flush the tail of each process
    # would be lost. Also registers the shutdown hook.
    initializer "agentkit.telemetry" do
      at_exit { Agentkit::Telemetry.flush! }

      config.after_initialize do
        next unless Agentkit.config.telemetry.enabled

        Agentkit::Telemetry.emit("app.boot",
                                 dims: { domain: Agentkit.config.domain_name,
                                         version: Agentkit::VERSION })
      end
    end

    # Cron entries are optional: the same processors are invocable from HTTP,
    # CLI or a flow step.
    initializer "agentkit.schedule", after: :load_config_initializers do
      next unless defined?(::Sidekiq::Cron::Job)

      entries = {}
      if (cron = Agentkit.config.memory.dreaming.cron)
        entries["agentkit_dreaming"] = { "cron" => cron, "class" => "Agentkit::CognitionJob", "args" => ["dreaming"] }
      end
      if (cron = Agentkit.config.factory.cycle[:diagnose])
        entries["agentkit_factory_diagnose"] = { "cron" => cron, "class" => "Agentkit::FactoryDiagnoseJob" }
      end
      entries["agentkit_embedding_flush"] = {
        "cron" => "*/5 * * * *", "class" => "Agentkit::EmbeddingFlushJob"
      }
      ::Sidekiq::Cron::Job.load_from_hash(entries) if entries.any?
    rescue StandardError => e
      Rails.logger.warn("[AgentKit] cron registration skipped: #{e.message}")
    end

    # Fails on boot instead of halfway through a production run.
    initializer "agentkit.validate_flows", after: :eager_load! do
      config.after_initialize do
        next unless Rails.env.production? || ENV["AGENTKIT_VALIDATE_FLOWS"]

        Agentkit::Flow::Registry.validate_all!
      end
    end

    initializer "agentkit.pgvector_check" do
      config.after_initialize do
        next unless Agentkit.config.memory.vectors?
        next unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection_pool.connected?

        unless ActiveRecord::Base.connection.extension_enabled?("vector")
          Rails.logger.warn("[AgentKit] pgvector is not enabled; memory falls back to :keyword mode.")
          Agentkit.config.memory.level = :keyword
        end
      rescue StandardError
        nil # never block boot on a database that is not ready
      end
    end

    rake_tasks do
      load File.expand_path("tasks/agentkit.rake", __dir__)
    end
  end
end
