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
    end
  end
end
