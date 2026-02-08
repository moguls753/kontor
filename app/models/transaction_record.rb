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
class TransactionRecord < ApplicationRecord
  belongs_to :account
  belongs_to :category, optional: true
  has_one :bank_connection, through: :account
  has_one :user, through: :bank_connection

  validates :transaction_id, presence: true, uniqueness: { scope: :account_id }
  validates :amount, presence: true
  validates :currency, presence: true
  validates :booking_date, presence: true

  scope :debits, -> { where("amount < 0") }
  scope :credits, -> { where("amount > 0") }
  scope :booked, -> { where(status: "booked") }
  scope :in_period, ->(from, to) { where(booking_date: from..to) }
  scope :uncategorized, -> { where(category_id: nil) }
end
