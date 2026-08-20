# frozen_string_literal: true

class TenantizeAgentkitFactory < ActiveRecord::Migration[7.1]
  GLOBAL_TENANT_KEY = "__global__"
  TABLES = %i[agentkit_findings agentkit_experiments agentkit_golden_cases agentkit_factory_runs].freeze

  def up
    if table_exists?(:agentkit_factory_runs) && column_exists?(:agentkit_factory_runs, :errors) &&
       !column_exists?(:agentkit_factory_runs, :error_details)
      rename_column :agentkit_factory_runs, :errors, :error_details
    end

    TABLES.each do |table|
      next unless table_exists?(table)

      add_column(table, :tenant_key, :string) unless column_exists?(table, :tenant_key)
      add_column(table, :account_id, :bigint) unless column_exists?(table, :account_id)
      execute "UPDATE #{quote_table_name(table)} SET tenant_key = #{quote(GLOBAL_TENANT_KEY)} WHERE tenant_key IS NULL OR tenant_key = ''"
      change_column_null(table, :tenant_key, false)
      change_column_default(table, :tenant_key, from: nil, to: GLOBAL_TENANT_KEY)
      add_index(table, :tenant_key) unless index_exists?(table, :tenant_key)
      add_index(table, :account_id) unless index_exists?(table, :account_id)
    end

    tenantize_finding_identity
    tenantize_experiment_identity
    tenantize_golden_identity

    return unless table_exists?(:agentkit_usage_events)

    execute "UPDATE agentkit_usage_events SET tenant_key = #{quote(GLOBAL_TENANT_KEY)} WHERE tenant_key IS NULL OR tenant_key = ''"
    change_column_null :agentkit_usage_events, :tenant_key, false
    change_column_default :agentkit_usage_events, :tenant_key, from: nil, to: GLOBAL_TENANT_KEY
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Factory records have been separated into tenant security boundaries"
  end

  private

  def tenantize_finding_identity
    remove_index :agentkit_findings, name: "idx_agentkit_active_finding_fingerprint" if
      index_name_exists?(:agentkit_findings, "idx_agentkit_active_finding_fingerprint")
    add_index :agentkit_findings, %i[tenant_key fingerprint], unique: true,
              where: "status IN ('open','accepted','experimenting')",
              name: "idx_agentkit_tenant_active_fingerprint"
  end

  def tenantize_experiment_identity
    remove_index :agentkit_experiments, name: "idx_agentkit_one_running_experiment_per_target" if
      index_name_exists?(:agentkit_experiments, "idx_agentkit_one_running_experiment_per_target")
    add_index :agentkit_experiments, %i[tenant_key target], unique: true,
              where: "status = 'running'", name: "idx_agentkit_tenant_running_target"
  end

  def tenantize_golden_identity
    remove_index :agentkit_golden_cases, name: "idx_agentkit_golden_unique_suggestion" if
      index_name_exists?(:agentkit_golden_cases, "idx_agentkit_golden_unique_suggestion")
    add_index :agentkit_golden_cases, %i[tenant_key agent_name suggestion_id], unique: true,
              where: "suggestion_id IS NOT NULL", name: "idx_agentkit_tenant_golden_suggestion"
  end
end
