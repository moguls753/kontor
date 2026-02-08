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
class Account < ApplicationRecord
  belongs_to :bank_connection
  has_many :transaction_records, dependent: :destroy
  has_one :user, through: :bank_connection

  validates :account_uid, presence: true
  validates :currency, presence: true

  def display_name
    name.presence || iban.presence || "Account #{id}"
  end
end
