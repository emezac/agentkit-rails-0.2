# frozen_string_literal: true

class AddAgentkitTenancy < ActiveRecord::Migration[7.1]
  GLOBAL_TENANT_KEY = "__global__"

  def up
    harden_knowledge_chunks
    harden_team_memory
  end

  def down
    # Tenant columns can contain the only distinction between otherwise
    # identical records. Removing them would merge security boundaries and can
    # violate the old global unique indexes, so this migration is intentionally
    # irreversible.
    raise ActiveRecord::IrreversibleMigration, "removing AgentKit tenant boundaries is unsafe"
  end

  private

  def harden_knowledge_chunks
    return unless table_exists?(:agentkit_knowledge_chunks)

    add_tenant_columns(:agentkit_knowledge_chunks)
    remove_index :agentkit_knowledge_chunks, name: "index_agentkit_knowledge_chunks_on_corpus_name_and_chunk_id" if
      index_name_exists?(:agentkit_knowledge_chunks, "index_agentkit_knowledge_chunks_on_corpus_name_and_chunk_id")
    add_index :agentkit_knowledge_chunks, %i[tenant_key corpus_name chunk_id],
              unique: true, name: "idx_agentkit_knowledge_tenant_chunk" unless
      index_name_exists?(:agentkit_knowledge_chunks, "idx_agentkit_knowledge_tenant_chunk")
    add_index :agentkit_knowledge_chunks, %i[tenant_key corpus_name chapter_index],
              name: "idx_agentkit_knowledge_tenant_chapter" unless
      index_name_exists?(:agentkit_knowledge_chunks, "idx_agentkit_knowledge_tenant_chapter")
  end

  def harden_team_memory
    return unless table_exists?(:agentkit_teams)

    %i[
      agentkit_teams agentkit_memory_assets agentkit_wiki_pages
      agentkit_code_symbols agentkit_asset_bindings
    ].each { |table| add_tenant_columns(table) if table_exists?(table) }

    remove_index :agentkit_teams, name: "index_agentkit_teams_on_name" if
      index_name_exists?(:agentkit_teams, "index_agentkit_teams_on_name")
    add_index :agentkit_teams, %i[tenant_key name], unique: true,
              name: "idx_agentkit_teams_tenant_name" unless
      index_name_exists?(:agentkit_teams, "idx_agentkit_teams_tenant_name")
    add_index :agentkit_memory_assets, %i[tenant_key asset_type name],
              name: "idx_agentkit_assets_tenant_type_name" unless
      index_name_exists?(:agentkit_memory_assets, "idx_agentkit_assets_tenant_type_name")
  end

  def add_tenant_columns(table)
    add_column table, :tenant_key, :string, null: false, default: GLOBAL_TENANT_KEY unless
      column_exists?(table, :tenant_key)
    add_column table, :account_id, :bigint unless column_exists?(table, :account_id)
    add_index table, :account_id unless index_exists?(table, :account_id)
    add_index table, :tenant_key unless index_exists?(table, :tenant_key)
  end
end
