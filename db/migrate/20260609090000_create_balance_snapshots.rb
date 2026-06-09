class CreateBalanceSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :balance_snapshots do |t|
      # No single-column index here — the composite unique index below covers
      # account_id-prefixed lookups (and is what the idempotent upsert conflicts on).
      t.references :account, null: false, foreign_key: true, index: false
      t.date :snapshot_on, null: false
      t.decimal :balance_amount, precision: 15, scale: 2
      t.string :currency, limit: 3, default: "EUR"

      t.timestamps
    end

    add_index :balance_snapshots, %i[account_id snapshot_on], unique: true
  end
end
