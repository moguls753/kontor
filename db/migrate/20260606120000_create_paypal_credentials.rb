class CreatePaypalCredentials < ActiveRecord::Migration[8.1]
  def change
    create_table :paypal_credentials do |t|
      # One PayPal credential per user. Columns are text because the values are
      # stored encrypted (ActiveRecord encryption envelope). The username +
      # password are the PayPal web login, replayed to the network-isolated
      # paypal-scraper sidecar on every manual sync.
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.text :username
      t.text :password

      t.timestamps
    end
  end
end
