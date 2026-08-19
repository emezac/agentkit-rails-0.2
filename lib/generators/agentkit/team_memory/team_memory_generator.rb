# frozen_string_literal: true

require "rails/generators"
require "rails/generators/migration"

module Agentkit
  module Generators
    # `rails g agentkit:team_memory`
    # Scaffolds Team Memory Hub configuration and copies migration 009_create_agentkit_team_memory.rb.
    class TeamMemoryGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      def self.next_migration_number(dirname)
        next_num = current_migration_number(dirname) + 1
        ActiveRecord::Migration.next_migration_number(next_num)
      end

      def copy_migration
        migration_template(
          File.expand_path("../../../../db/migrate/009_create_agentkit_team_memory.rb", __dir__),
          "db/migrate/create_agentkit_team_memory.rb"
        )
      end

      def show_next_steps
        say <<~MSG, :green

          AgentKit Team Memory Hub installed.

            rails db:migrate
            # Access team memory hub web dashboard at /agentkit/team_memory
            # Or equip agents in code:

            class MyAgent < ApplicationAgent
              belongs_to_team "SecurityTeam"
            end

        MSG
      end
    end
  end
end
