# frozen_string_literal: true

require "rails/generators"
require "rails/generators/migration"

module Agentkit
  module Generators
    # `rails g agentkit:rag`
    # Scaffolds native RAG configuration and copies migration 007_create_agentkit_knowledge.rb.
    class RagGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      def self.next_migration_number(dirname)
        next_num = current_migration_number(dirname) + 1
        ActiveRecord::Migration.next_migration_number(next_num)
      end

      def copy_migration
        migration_template(
          File.expand_path("../../../../db/migrate/007_create_agentkit_knowledge.rb", __dir__),
          "db/migrate/create_agentkit_knowledge.rb"
        )
      rescue StandardError => e
        say "Migration already exists or skipped: #{e.message}", :yellow
      end

      def show_next_steps
        say <<~MSG, :green

          AgentKit RAG module installed.

            rails db:migrate
            # Now you can use Agentkit::RAG.index or `use_knowledge` in your agents:

            class MyAgent < ApplicationAgent
              use_knowledge :my_corpus
            end

        MSG
      end
    end
  end
end
