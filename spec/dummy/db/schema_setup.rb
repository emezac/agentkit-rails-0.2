# frozen_string_literal: true

# Builds the dummy app's own tables and then runs the engine's migrations, so
# the specs exercise the exact SQL a host application would get from
# `rails agentkit:install:migrations`.
module DummySchema
  ENGINE_MIGRATIONS = File.expand_path("../../../db/migrate", __dir__)

  module_function

  def load!
    connection = ActiveRecord::Base.connection
    return if connection.table_exists?(:agentkit_run_steps) && connection.table_exists?(:widgets)

    ActiveRecord::Migration.suppress_messages do
      create_domain_tables(connection)
      run_engine_migrations
    end
  end

  def create_domain_tables(connection)
    unless connection.table_exists?(:accounts)
      connection.create_table :accounts do |t|
        t.string :name, null: false
        t.string :plan, default: "pro"
        t.timestamps
      end
    end

    return if connection.table_exists?(:widgets)

    connection.create_table :widgets do |t|
      t.references :account, null: false
      t.string  :name, null: false
      t.string  :status, default: "new"
      t.timestamps
    end
  end

  def run_engine_migrations
    context = ActiveRecord::MigrationContext.new(ENGINE_MIGRATIONS)
    context.migrate
  end

  def truncate!
    connection = ActiveRecord::Base.connection
    tables = connection.tables - %w[schema_migrations ar_internal_metadata]
    return if tables.empty?

    connection.execute("TRUNCATE #{tables.join(', ')} RESTART IDENTITY CASCADE")
  end
end
