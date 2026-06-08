class CreateRecurringSeries < ActiveRecord::Migration[8.1]
  def change
    create_table :recurring_series do |t|
      t.references :user, null: false, foreign_key: true
      t.references :category, foreign_key: true
      t.string  :canonical_name, null: false
      t.string  :merchant_type
      t.string  :direction, null: false
      t.string  :cadence, null: false
      t.integer :cadence_days
      t.decimal :expected_amount, precision: 15, scale: 2
      t.boolean :amount_variable, null: false, default: false
      t.decimal :amount_min, precision: 15, scale: 2
      t.decimal :amount_max, precision: 15, scale: 2
      t.string  :currency, limit: 3, null: false
      t.decimal :confidence, precision: 4, scale: 3, null: false, default: 0
      t.string  :status, null: false, default: "active"
      t.boolean :user_confirmed, null: false, default: false
      t.integer :occurrences_count, null: false, default: 0
      t.date    :first_seen_on
      t.date    :last_seen_on
      t.date    :next_expected_on
      t.string  :fingerprint, null: false
      t.timestamps
    end

    add_index :recurring_series, [ :user_id, :fingerprint ]
    add_index :recurring_series, [ :user_id, :status ]
  end
end
