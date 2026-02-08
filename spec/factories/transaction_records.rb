# == Schema Information
#
# Table name: transaction_records
#
#  id                    :integer          not null, primary key
#  amount                :decimal(15, 2)   not null
#  bank_transaction_code :string
#  booking_date          :date             not null
#  creditor_iban         :string
#  creditor_name         :string
#  currency              :string(3)        not null
#  debtor_iban           :string
#  debtor_name           :string
#  entry_reference       :string
#  remittance            :text
#  status                :string           default("booked")
#  value_date            :date
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  account_id            :integer          not null
#  category_id           :integer
#  transaction_id        :string           not null
#
# Indexes
#
#  index_transaction_records_on_account_id                     (account_id)
#  index_transaction_records_on_account_id_and_transaction_id  (account_id,transaction_id) UNIQUE
#  index_transaction_records_on_booking_date                   (booking_date)
#  index_transaction_records_on_category_id                    (category_id)
#
# Foreign Keys
#
#  account_id   (account_id => accounts.id)
#  category_id  (category_id => categories.id)
#
FactoryBot.define do
  factory :transaction_record do
    account
    transaction_id { SecureRandom.uuid }
    amount { -42.50 }
    currency { "EUR" }
    booking_date { Date.current }
    value_date { Date.current }
    status { "booked" }
    remittance { "REWE Markt Freiburg" }
    creditor_name { "REWE Markt GmbH" }

    trait :credit do
      amount { 2500.00 }
      remittance { "Gehalt Januar" }
      creditor_name { nil }
      debtor_name { "Arbeitgeber GmbH" }
    end

    trait :pending do
      status { "pending" }
    end
  end
end
