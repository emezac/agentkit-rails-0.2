# frozen_string_literal: true

class CreateAgentkitTeamMemory < ActiveRecord::Migration[7.1]
  def change
    create_table :agentkit_teams do |t|
      t.string :tenant_key,   null: false, default: "__global__"
      t.string :name,        null: false
      t.text   :description
      t.bigint :owner_id
      t.bigint :account_id
      t.jsonb  :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :agentkit_teams, %i[tenant_key name], unique: true,
              name: "idx_agentkit_teams_tenant_name"
    add_index :agentkit_teams, :account_id

    create_table :agentkit_memory_assets do |t|
      t.string     :tenant_key, null: false, default: "__global__"
      t.bigint     :account_id
      t.references :team,        foreign_key: { to_table: :agentkit_teams }, null: true
      t.string     :asset_type,  null: false # chat_memory | skill | wiki | code_graph
      t.string     :name,        null: false
      t.string     :visibility,  null: false, default: "team" # private | team | restricted | agent
      t.bigint     :owner_id
      t.string     :version,     null: false, default: "1.0.0"
      t.string     :status,      null: false, default: "ready"
      t.integer    :usage_count, null: false, default: 0
      t.jsonb      :content,     null: false, default: {}
      t.jsonb      :bindings,    null: false, default: []
      t.timestamps
    end
    add_index :agentkit_memory_assets, %i[asset_type name]
    add_index :agentkit_memory_assets, %i[team_id visibility]
    add_index :agentkit_memory_assets, %i[tenant_key asset_type name],
              name: "idx_agentkit_assets_tenant_type_name"
    add_index :agentkit_memory_assets, :account_id

    create_table :agentkit_wiki_pages do |t|
      t.string     :tenant_key, null: false, default: "__global__"
      t.bigint     :account_id
      t.references :asset,   foreign_key: { to_table: :agentkit_memory_assets }, null: false
      t.string     :title,   null: false
      t.text       :content, null: false
      t.jsonb      :links,   null: false, default: []
      t.string     :status,  null: false, default: "ready"
      t.timestamps
    end
    add_index :agentkit_wiki_pages, %i[asset_id title]
    add_index :agentkit_wiki_pages, :tenant_key

    create_table :agentkit_code_symbols do |t|
      t.string     :tenant_key, null: false, default: "__global__"
      t.bigint     :account_id
      t.references :asset,       foreign_key: { to_table: :agentkit_memory_assets }, null: false
      t.string     :name,        null: false
      t.string     :symbol_type, null: false # class | method | module | function
      t.string     :file_path,   null: false
      t.integer    :line_number
      t.jsonb      :callers,     null: false, default: []
      t.jsonb      :callees,     null: false, default: []
      t.timestamps
    end
    add_index :agentkit_code_symbols, %i[asset_id name]
    add_index :agentkit_code_symbols, %i[asset_id file_path]
    add_index :agentkit_code_symbols, :tenant_key

    create_table :agentkit_asset_bindings do |t|
      t.string     :tenant_key, null: false, default: "__global__"
      t.bigint     :account_id
      t.references :asset,       foreign_key: { to_table: :agentkit_memory_assets }, null: false
      t.string     :agent_name,  null: false
      t.string     :target_type
      t.bigint     :target_id
      t.integer    :priority,    null: false, default: 50
      t.timestamps
    end
    add_index :agentkit_asset_bindings, %i[asset_id agent_name], unique: true
    add_index :agentkit_asset_bindings, :tenant_key
  end
end
