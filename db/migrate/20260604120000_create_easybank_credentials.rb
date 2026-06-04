class CreateEasybankCredentials < ActiveRecord::Migration[8.1]
  def change
    create_table :easybank_credentials do |t|
      # One easybank credential per user. Columns are text because the values are
      # stored encrypted (ActiveRecord encryption envelope). last_paired_at records
      # when the sidecar last completed a device-pairing mTAN, so a lost sidecar
      # profile doesn't silently re-trigger the interactive backfill mTAN.
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.text :username
      t.text :password
      t.datetime :last_paired_at

      t.timestamps
    end
  end
end
