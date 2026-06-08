class CreateMerchantAliases < ActiveRecord::Migration[8.1]
  def change
    create_table :merchant_aliases do |t|
      t.references :user, null: false, foreign_key: true
      t.string :raw_key, null: false
      t.string :canonical_name, null: false
      t.string :merchant_type
      t.string :source, null: false, default: "llm"
      t.timestamps
    end

    add_index :merchant_aliases, [ :user_id, :raw_key ], unique: true
    add_index :merchant_aliases, :canonical_name
  end
end
