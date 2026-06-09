# == Schema Information
#
# Table name: balance_snapshots
#
#  id             :integer          not null, primary key
#  balance_amount :decimal(15, 2)
#  currency       :string(3)        default("EUR")
#  snapshot_on    :date             not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  account_id     :integer          not null
#
# Indexes
#
#  index_balance_snapshots_on_account_id_and_snapshot_on  (account_id,snapshot_on) UNIQUE
#
# Foreign Keys
#
#  account_id  (account_id => accounts.id)
#
FactoryBot.define do
  factory :balance_snapshot do
    account
    snapshot_on { Date.current }
    balance_amount { 1000.00 }
    currency { "EUR" }
  end
end
