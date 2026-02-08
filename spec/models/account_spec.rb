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
require "rails_helper"

RSpec.describe Account, type: :model do
  it "is valid with required attributes" do
    expect(build(:account)).to be_valid
  end

  it "requires account_uid" do
    expect(build(:account, account_uid: nil)).not_to be_valid
  end

  it "falls back display_name to iban then id" do
    expect(build(:account, name: "Giro").display_name).to eq("Giro")
    expect(build(:account, name: nil, iban: "DE89").display_name).to eq("DE89")
    account = create(:account, name: nil, iban: nil)
    expect(account.display_name).to eq("Account #{account.id}")
  end
end
