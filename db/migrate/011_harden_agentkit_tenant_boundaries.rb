# frozen_string_literal: true

class HardenAgentkitTenantBoundaries < ActiveRecord::Migration[7.1]
  GLOBAL_TENANT_KEY = "__global__"

  TENANT_TABLES = %i[
    agentkit_runs agentkit_run_steps agentkit_artifacts agentkit_suggestions
    agentkit_decisions agentkit_audit_logs agentkit_traces agentkit_trace_phases
  ].freeze

  def up
    add_column(:agentkit_run_steps, :tenant_key, :string) if table_exists?(:agentkit_run_steps) && !column_exists?(:agentkit_run_steps, :tenant_key)
    execute <<~SQL.squish if table_exists?(:agentkit_run_steps)
      UPDATE agentkit_run_steps AS steps
      SET tenant_key = runs.tenant_key
      FROM agentkit_runs AS runs
      WHERE steps.run_id = runs.id AND steps.tenant_key IS NULL
    SQL
    execute <<~SQL.squish if table_exists?(:agentkit_artifacts)
      UPDATE agentkit_artifacts AS artifacts
      SET tenant_key = runs.tenant_key
      FROM agentkit_runs AS runs
      WHERE artifacts.run_id = runs.id AND artifacts.tenant_key IS NULL
    SQL

    TENANT_TABLES.each do |table|
      next unless table_exists?(table)

      add_column(table, :tenant_key, :string) unless column_exists?(table, :tenant_key)
      execute <<~SQL.squish
        UPDATE #{quote_table_name(table)}
        SET tenant_key = #{quote(GLOBAL_TENANT_KEY)}
        WHERE tenant_key IS NULL OR tenant_key = ''
      SQL
      change_column_null(table, :tenant_key, false)
      change_column_default(table, :tenant_key, from: nil, to: GLOBAL_TENANT_KEY)
      add_index(table, :tenant_key) unless index_exists?(table, :tenant_key)
    end

    if table_exists?(:agentkit_runs)
      remove_index :agentkit_runs, :idempotency_key if index_exists?(:agentkit_runs, :idempotency_key)
      add_index :agentkit_runs, %i[tenant_key idempotency_key], unique: true,
                where: "idempotency_key IS NOT NULL", name: "idx_agentkit_runs_tenant_idempotency"
    end

    if table_exists?(:agentkit_suggestions)
      remove_index :agentkit_suggestions, :idempotency_key if index_exists?(:agentkit_suggestions, :idempotency_key)
      add_index :agentkit_suggestions, %i[tenant_key idempotency_key],
                where: "idempotency_key IS NOT NULL", name: "idx_agentkit_suggestions_tenant_idempotency"
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Tenant backfill and compound security boundaries cannot be safely merged"
  end
end
