# == Schema Information
#
# Table name: accounts
#
#  id                  :integer          not null, primary key
#  account_type        :string
#  account_uid         :string           not null
#  balance_amount      :decimal(15, 2)
#  balance_type        :string
#  balance_updated_at  :datetime
#  currency            :string(3)        default("EUR")
#  iban                :string
#  identification_hash :string
#  last_synced_at      :datetime
#  name                :string
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  bank_connection_id  :integer          not null
#
# Indexes
#
#  index_accounts_on_account_uid          (account_uid)
#  index_accounts_on_bank_connection_id   (bank_connection_id)
#  index_accounts_on_identification_hash  (identification_hash)
#
# Foreign Keys
#
#  bank_connection_id  (bank_connection_id => bank_connections.id)
#
FactoryBot.define do
  factory :account do
    bank_connection
    account_uid { SecureRandom.uuid }
    iban { "DE89370400440532013000" }
    name { "Girokonto" }
    currency { "EUR" }
    balance_amount { 1234.56 }
    balance_type { "CLBD" }
  end
end
