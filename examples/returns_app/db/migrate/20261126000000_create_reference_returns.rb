# frozen_string_literal: true
class CreateReferenceReturns < ActiveRecord::Migration[7.1]
  def change
    create_table :reference_returns do |t|
      t.string :tenant_key, null: false
      t.bigint :account_id, null: false
      t.string :requested_by, null: false
      t.string :approved_by
      t.string :approval_digest
      t.integer :amount_cents, null: false
      t.string :currency, null: false, default: "MXN"
      t.string :status, null: false, default: "requested"
      t.timestamps
    end
    add_check_constraint :reference_returns, "amount_cents > 0 AND amount_cents <= 100000", name: "reference_return_amount"
    create_table :reference_refund_intents do |t|
      t.references :return_request, null: false, index: { unique: true }, foreign_key: { to_table: :reference_returns }
      t.string :provider_key, null: false
      t.string :execution_key, null: false
      t.string :delivery_queue, null: false, default: "standard"
      t.string :status, null: false, default: "pending"
      t.integer :amount_cents, null: false
      t.string :currency, null: false
      t.string :lease_token
      t.datetime :lease_until
      t.jsonb :confirmation
      t.timestamps
    end
    add_index :reference_refund_intents, :provider_key, unique: true
    # Local provider simulator only. A real provider owns its separate ledger.
    create_table :reference_provider_refunds do |t|
      t.string :provider_key, null: false
      t.integer :amount_cents, null: false
      t.string :currency, null: false
      t.timestamps
    end
    add_index :reference_provider_refunds, :provider_key, unique: true
  end
end
