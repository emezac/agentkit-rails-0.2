# frozen_string_literal: true

class HardenAgentkitHitlAndAudit < ActiveRecord::Migration[7.1]
  OLD_INDEX = "idx_agentkit_suggestions_tenant_idempotency"
  NEW_INDEX = "idx_agentkit_suggestions_durable_idempotency"

  def up
    return unless table_exists?(:agentkit_suggestions)

    add_column :agentkit_suggestions, :operation_namespace, :string unless column_exists?(:agentkit_suggestions, :operation_namespace)
    add_column :agentkit_suggestions, :arguments_digest, :string unless column_exists?(:agentkit_suggestions, :arguments_digest)
    add_column :agentkit_suggestions, :lock_version, :integer, null: false, default: 0 unless column_exists?(:agentkit_suggestions, :lock_version)
    add_column :agentkit_suggestions, :execution_error_code, :string unless column_exists?(:agentkit_suggestions, :execution_error_code)
    add_column :agentkit_suggestions, :execution_started_at, :datetime unless column_exists?(:agentkit_suggestions, :execution_started_at)
    add_column :agentkit_suggestions, :execution_finished_at, :datetime unless column_exists?(:agentkit_suggestions, :execution_finished_at)

    execute <<~SQL.squish
      UPDATE agentkit_suggestions
      SET operation_namespace = 'hitl.suggest:' || suggestion_type
      WHERE operation_namespace IS NULL OR operation_namespace = ''
    SQL

    # Historical rows were only deduplicated inside a time window, so the same
    # key may legitimately exist more than once. Preserve every row and move
    # later duplicates into a stable legacy namespace before enforcing the new
    # durable contract.
    execute <<~SQL.squish
      WITH ranked AS (
        SELECT id,
               ROW_NUMBER() OVER (
                 PARTITION BY tenant_key, operation_namespace, idempotency_key
                 ORDER BY id
               ) AS duplicate_rank
        FROM agentkit_suggestions
        WHERE idempotency_key IS NOT NULL
      )
      UPDATE agentkit_suggestions AS suggestions
      SET operation_namespace = suggestions.operation_namespace || ':legacy:' || suggestions.id
      FROM ranked
      WHERE suggestions.id = ranked.id AND ranked.duplicate_rank > 1
    SQL

    remove_index :agentkit_suggestions, name: OLD_INDEX if index_exists?(:agentkit_suggestions, name: OLD_INDEX)
    add_index :agentkit_suggestions,
              %i[tenant_key operation_namespace idempotency_key],
              unique: true,
              where: "idempotency_key IS NOT NULL",
              name: NEW_INDEX unless index_exists?(:agentkit_suggestions, name: NEW_INDEX)
    add_index :agentkit_suggestions, %i[tenant_key status execution_started_at],
              name: "idx_agentkit_suggestions_execution" unless index_exists?(:agentkit_suggestions, name: "idx_agentkit_suggestions_execution")
  end

  def down
    return unless table_exists?(:agentkit_suggestions)

    remove_index :agentkit_suggestions, name: "idx_agentkit_suggestions_execution" if index_exists?(:agentkit_suggestions, name: "idx_agentkit_suggestions_execution")
    remove_index :agentkit_suggestions, name: NEW_INDEX if index_exists?(:agentkit_suggestions, name: NEW_INDEX)
    add_index :agentkit_suggestions, %i[tenant_key idempotency_key],
              where: "idempotency_key IS NOT NULL", name: OLD_INDEX unless index_exists?(:agentkit_suggestions, name: OLD_INDEX)

    %i[execution_finished_at execution_started_at execution_error_code lock_version arguments_digest operation_namespace].each do |column|
      remove_column :agentkit_suggestions, column if column_exists?(:agentkit_suggestions, column)
    end
  end
end
