# frozen_string_literal: true

class RenameFactoryRunErrors < ActiveRecord::Migration[7.1]
  def up
    return unless table_exists?(:agentkit_factory_runs)
    return unless column_exists?(:agentkit_factory_runs, :errors)
    return if column_exists?(:agentkit_factory_runs, :error_details)

    rename_column :agentkit_factory_runs, :errors, :error_details
  end

  def down
    return unless table_exists?(:agentkit_factory_runs)
    return unless column_exists?(:agentkit_factory_runs, :error_details)
    return if column_exists?(:agentkit_factory_runs, :errors)

    rename_column :agentkit_factory_runs, :error_details, :errors
  end
end
