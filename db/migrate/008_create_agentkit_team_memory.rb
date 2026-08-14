# frozen_string_literal: true

class CreateAgentkitTeamMemory < ActiveRecord::Migration[7.1]
  def change
    create_table :agentkit_teams do |t|
      t.string :name,        null: false
      t.text   :description
      t.bigint :owner_id
      t.bigint :account_id
      t.jsonb  :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :agentkit_teams, :name, unique: true

    create_table :agentkit_memory_assets do |t|
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

    create_table :agentkit_wiki_pages do |t|
      t.references :asset,   foreign_key: { to_table: :agentkit_memory_assets }, null: false
      t.string     :title,   null: false
      t.text       :content, null: false
      t.jsonb      :links,   null: false, default: []
      t.string     :status,  null: false, default: "ready"
      t.timestamps
    end
    add_index :agentkit_wiki_pages, %i[asset_id title]

    create_table :agentkit_code_symbols do |t|
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

    create_table :agentkit_asset_bindings do |t|
      t.references :asset,       foreign_key: { to_table: :agentkit_memory_assets }, null: false
      t.string     :agent_name,  null: false
      t.string     :target_type
      t.bigint     :target_id
      t.integer    :priority,    null: false, default: 50
      t.timestamps
    end
    add_index :agentkit_asset_bindings, %i[asset_id agent_name], unique: true
  end
end
