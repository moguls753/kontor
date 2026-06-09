# == Schema Information
#
# Table name: accounts
#
#  id                  :integer          not null, primary key
#  account_type        :string
#  account_uid         :string           not null
#  available_credit    :decimal(15, 2)
#  balance_amount      :decimal(15, 2)
#  balance_type        :string
#  balance_updated_at  :datetime
#  credit_limit        :decimal(15, 2)
#  currency            :string(3)        default("EUR")
#  iban                :string
#  identification_hash :string
#  last_synced_at      :datetime
#  name                :string
#  role                :string
#  role_locked         :boolean          default(FALSE), not null
#  shared              :boolean          default(FALSE), not null
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

  it "validates role against ROLES" do
    expect(build(:account, role: "investment")).to be_valid
    expect(build(:account, role: nil)).to be_valid
    expect(build(:account, role: "bogus")).not_to be_valid
  end

  it "scopes shared and personal accounts" do
    shared = create(:account, shared: true, role_locked: true)
    personal = create(:account, shared: false, role_locked: true)

    expect(Account.shared).to include(shared)
    expect(Account.shared).not_to include(personal)
    expect(Account.personal).to include(personal)
    expect(Account.personal).not_to include(shared)
  end

  it "knows saving destinations" do
    expect(build(:account, role: "sparkonto").saving_destination?).to be(true)
    expect(build(:account, role: "investment").saving_destination?).to be(true)
    expect(build(:account, role: "giro").saving_destination?).to be(false)
  end

  it "infers a role on create from the provider" do
    bc = create(:bank_connection, :trade_republic)
    account = create(:account, bank_connection: bc)
    expect(account.reload.role).to eq("investment")
  end

  it "does not override a role_locked account on save" do
    account = create(:account, bank_connection: create(:bank_connection, :trade_republic),
                               role: "giro", role_locked: true)
    expect(account.reload.role).to eq("giro")
  end
end
