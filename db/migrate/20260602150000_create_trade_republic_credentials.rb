class CreateTradeRepublicCredentials < ActiveRecord::Migration[8.1]
  def change
    create_table :trade_republic_credentials do |t|
      # One Trade Republic credential per user. Columns are text because the
      # values are stored encrypted (ActiveRecord encryption envelope).
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.text :phone_number
      t.text :pin
      t.text :session_blob
      t.datetime :last_paired_at

      t.timestamps
    end
  end
end
