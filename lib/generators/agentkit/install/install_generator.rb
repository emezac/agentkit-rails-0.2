# frozen_string_literal: true

require "rails/generators"
require "rails/generators/migration"

module Agentkit
  module Generators
    # `rails g agentkit:install [--with-chat]`
    #
    # Installs the initializer, the domain ApplicationAgent, the migrations and
    # — with --with-chat — a working proposal-first chat: Setup, one capability,
    # its flow and the controller.
    #
    # The point of scaffolding all of it on day 0 is the factory: telemetry and
    # the decision ledger only become useful after weeks of data, so they have
    # to start collecting from the first commit, not when someone remembers.
    class InstallGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      class_option :with_chat, type: :boolean, default: false,
                               desc: "Also scaffold the proposal-first chat"

      def self.next_migration_number(_path)
        Time.now.utc.strftime("%Y%m%d%H%M%S")
      end

      # A Rails::Engine loaded from config/initializers is already too late:
      # Rails has collected its railties, so the constant exists but its model
      # paths and `agentkit:install:migrations` task never get registered.
      # Install the engine at application boot before creating the initializer
      # or invoking the migration task in a fresh Rails process.
      def install_engine_boot
        application = "config/application.rb"
        source = File.read(destination_root_path(application))
        core_require = /^require ["']agentkit["']\s*$/
        engine_require = /^require ["']agentkit\/engine["']\s*$/

        if source.match?(core_require) && source.match?(engine_require)
          say_status :identical, application
        elsif source.match?(core_require)
          inject_into_file application, after: core_require do
            "\nrequire \"agentkit/engine\""
          end
        elsif source.match?(engine_require)
          inject_into_file application, before: engine_require do
            "require \"agentkit\"\n"
          end
        else
          inject_into_file application, after: rails_boot_anchor(source) do
            "\nrequire \"agentkit\"\nrequire \"agentkit/engine\"\n"
          end
        end
      end

      def copy_initializer
        template "initializer.rb", "config/initializers/agentkit.rb"
      end

      def copy_application_agent
        template "application_agent.rb", "app/agents/application_agent.rb"
      end

      def install_migrations
        rake "agentkit:install:migrations"
      end

      def copy_chat_scaffold
        return unless options[:with_chat]

        template "operating_profile.rb", "app/setup/operating_profile.rb"
        template "example_capability.rb", "app/capabilities/example_capability.rb"
        template "example_flow.rb",       "app/flows/example_flow.rb"
        template "chat_controller.rb",    "app/controllers/agent_chat_controller.rb"
        route %(resource :agent_chat, only: %i[show create])
      end

      def mount_engine
        route %(mount Agentkit::Engine => "/agentkit")
      end

      def show_next_steps
        say <<~MSG, :green

          AgentKit installed.

            rails db:migrate
            rails agentkit:doctor          # what is instrumented and what is missing
            /agentkit/runs                 # flow dashboard
            /agentkit/factory              # findings, ledger, economics

          Factory starts in :observe mode — it only accumulates statistics.
          Raise it to :suggest once you have ~60 human decisions per agent.
        MSG
      end

      private

      def destination_root_path(relative_path)
        File.expand_path(relative_path, destination_root)
      end

      def rails_boot_anchor(source)
        rails_require = source.lines.reverse.find do |line|
          line.match?(%r{\Arequire ["'](?:rails(?:/all|/application)?|[^"']+/railtie)["']\s*\z})
        end

        return rails_require if rails_require

        raise Thor::Error,
              "Could not find the Rails requires in config/application.rb; load agentkit/engine there manually."
      end
    end
  end
end
