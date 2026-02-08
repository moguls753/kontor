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
require "rails_helper"

RSpec.describe TransactionRecord, type: :model do
  it "is valid with required attributes" do
    expect(build(:transaction_record)).to be_valid
  end

  it "requires transaction_id, amount, currency, booking_date" do
    %i[transaction_id amount currency booking_date].each do |attr|
      expect(build(:transaction_record, attr => nil)).not_to be_valid
    end
  end

  it "requires unique transaction_id per account" do
    account = create(:account)
    create(:transaction_record, account: account, transaction_id: "TX123")
    expect(build(:transaction_record, account: account, transaction_id: "TX123")).not_to be_valid
  end
end
