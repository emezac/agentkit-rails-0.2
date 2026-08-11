# frozen_string_literal: true

class HardenAgentkitFactory < ActiveRecord::Migration[7.1]
  ACTIVE_FINDING_STATUSES = %w[open accepted experimenting].freeze

  def up
    harden_findings
    harden_experiments
    connect_decisions_to_experiments
    harden_golden_cases
    create_factory_runs
  end

  def down
    drop_table :agentkit_factory_runs if table_exists?(:agentkit_factory_runs)

    remove_reference :agentkit_decisions, :experiment, foreign_key: { to_table: :agentkit_experiments } if
      column_exists?(:agentkit_decisions, :experiment_id)
    remove_column :agentkit_decisions, :experiment_arm if column_exists?(:agentkit_decisions, :experiment_arm)
    remove_reference :agentkit_suggestions, :experiment, foreign_key: { to_table: :agentkit_experiments } if
      column_exists?(:agentkit_suggestions, :experiment_id)
    remove_column :agentkit_suggestions, :experiment_arm if column_exists?(:agentkit_suggestions, :experiment_arm)

    remove_index :agentkit_golden_cases, name: "idx_agentkit_golden_unique_suggestion" if
      index_name_exists?(:agentkit_golden_cases, "idx_agentkit_golden_unique_suggestion")
    if column_exists?(:agentkit_golden_cases, :reviewed)
      add_column :agentkit_golden_cases, :frozen, :boolean, null: false, default: false unless
        column_exists?(:agentkit_golden_cases, :frozen)
      execute "UPDATE agentkit_golden_cases SET frozen = reviewed"
      remove_column :agentkit_golden_cases, :reviewed
    end

    %i[cohort last_evaluated_at lock_version].each do |column|
      remove_column :agentkit_experiments, column if column_exists?(:agentkit_experiments, column)
    end

    remove_index :agentkit_findings, name: "idx_agentkit_active_finding_fingerprint" if
      index_name_exists?(:agentkit_findings, "idx_agentkit_active_finding_fingerprint")
    %i[fingerprint occurrence_count first_seen_at last_seen_at resolved_at resolved_by
       resolution_reason clean_cycles].each do |column|
      remove_column :agentkit_findings, column if column_exists?(:agentkit_findings, column)
    end
  end

  private

  def harden_findings
    add_column :agentkit_findings, :fingerprint, :string unless column_exists?(:agentkit_findings, :fingerprint)
    add_column :agentkit_findings, :occurrence_count, :integer, null: false, default: 1 unless
      column_exists?(:agentkit_findings, :occurrence_count)
    add_column :agentkit_findings, :first_seen_at, :datetime unless column_exists?(:agentkit_findings, :first_seen_at)
    add_column :agentkit_findings, :last_seen_at, :datetime unless column_exists?(:agentkit_findings, :last_seen_at)
    add_column :agentkit_findings, :resolved_at, :datetime unless column_exists?(:agentkit_findings, :resolved_at)
    add_column :agentkit_findings, :resolved_by, :string unless column_exists?(:agentkit_findings, :resolved_by)
    add_column :agentkit_findings, :resolution_reason, :text unless
      column_exists?(:agentkit_findings, :resolution_reason)
    add_column :agentkit_findings, :clean_cycles, :integer, null: false, default: 0 unless
      column_exists?(:agentkit_findings, :clean_cycles)

    execute <<~SQL
      UPDATE agentkit_findings
         SET fingerprint = encode(digest(lower(trim(detector)) || ':' ||
                                         lower(trim(coalesce(subject, ''))), 'sha256'), 'hex'),
             first_seen_at = coalesce(first_seen_at, created_at),
             last_seen_at = coalesce(last_seen_at, updated_at, created_at)
       WHERE fingerprint IS NULL OR first_seen_at IS NULL OR last_seen_at IS NULL
    SQL
    change_column_null :agentkit_findings, :fingerprint, false
    change_column_null :agentkit_findings, :first_seen_at, false
    change_column_null :agentkit_findings, :last_seen_at, false

    statuses = ACTIVE_FINDING_STATUSES.map { |status| connection.quote(status) }.join(", ")
    execute <<~SQL
      WITH ranked AS (
        SELECT id,
               row_number() OVER (PARTITION BY fingerprint ORDER BY updated_at DESC, id DESC) AS position
          FROM agentkit_findings
         WHERE status IN (#{statuses})
      )
      UPDATE agentkit_findings
         SET status = 'dismissed',
             resolved_at = now(),
             resolved_by = 'migration',
             resolution_reason = 'deduplicated_by_factory_hardening'
       WHERE id IN (SELECT id FROM ranked WHERE position > 1)
    SQL

    add_index :agentkit_findings, :fingerprint, unique: true,
              where: "status IN ('open','accepted','experimenting')",
              name: "idx_agentkit_active_finding_fingerprint" unless
      index_name_exists?(:agentkit_findings, "idx_agentkit_active_finding_fingerprint")
  end

  def harden_experiments
    add_column :agentkit_experiments, :cohort, :jsonb, null: false, default: {} unless
      column_exists?(:agentkit_experiments, :cohort)
    add_column :agentkit_experiments, :last_evaluated_at, :datetime unless
      column_exists?(:agentkit_experiments, :last_evaluated_at)
    add_column :agentkit_experiments, :lock_version, :integer, null: false, default: 0 unless
      column_exists?(:agentkit_experiments, :lock_version)

    add_index :agentkit_experiments, :target, unique: true, where: "status = 'running'",
              name: "idx_agentkit_one_running_experiment_per_target" unless
      index_name_exists?(:agentkit_experiments, "idx_agentkit_one_running_experiment_per_target")
  end

  def connect_decisions_to_experiments
    unless column_exists?(:agentkit_suggestions, :experiment_id)
      add_reference :agentkit_suggestions, :experiment,
                    foreign_key: { to_table: :agentkit_experiments }, null: true
    end
    add_column :agentkit_suggestions, :experiment_arm, :string unless
      column_exists?(:agentkit_suggestions, :experiment_arm)

    unless column_exists?(:agentkit_decisions, :experiment_id)
      add_reference :agentkit_decisions, :experiment,
                    foreign_key: { to_table: :agentkit_experiments }, null: true
    end
    add_column :agentkit_decisions, :experiment_arm, :string unless
      column_exists?(:agentkit_decisions, :experiment_arm)
    add_index :agentkit_decisions, %i[experiment_id experiment_arm mode],
              name: "idx_agentkit_decisions_experiment_cohort" unless
      index_name_exists?(:agentkit_decisions, "idx_agentkit_decisions_experiment_cohort")
  end

  def harden_golden_cases
    add_column :agentkit_golden_cases, :reviewed, :boolean, null: false, default: false unless
      column_exists?(:agentkit_golden_cases, :reviewed)
    if column_exists?(:agentkit_golden_cases, :frozen)
      execute "UPDATE agentkit_golden_cases SET reviewed = frozen"
      remove_column :agentkit_golden_cases, :frozen
    end

    execute <<~SQL
      DELETE FROM agentkit_golden_cases older
       USING agentkit_golden_cases newer
       WHERE older.agent_name = newer.agent_name
         AND older.suggestion_id = newer.suggestion_id
         AND older.id < newer.id
    SQL
    add_index :agentkit_golden_cases, %i[agent_name suggestion_id], unique: true,
              where: "suggestion_id IS NOT NULL",
              name: "idx_agentkit_golden_unique_suggestion" unless
      index_name_exists?(:agentkit_golden_cases, "idx_agentkit_golden_unique_suggestion")
  end

  def create_factory_runs
    return if table_exists?(:agentkit_factory_runs)

    create_table :agentkit_factory_runs do |t|
      t.string :status, null: false, default: "running"
      t.integer :window_days, null: false
      t.integer :detector_count, null: false, default: 0
      t.integer :fired_count, null: false, default: 0
      t.integer :created_count, null: false, default: 0
      t.integer :deduplicated_count, null: false, default: 0
      t.integer :experiments_evaluated, null: false, default: 0
      t.jsonb :errors, null: false, default: []
      t.jsonb :metadata, null: false, default: {}
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.timestamps
    end
    add_index :agentkit_factory_runs, %i[status started_at]
  end
end
