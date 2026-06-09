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
require "rails_helper"

RSpec.describe BalanceSnapshot, type: :model do
  it "belongs to an account" do
    expect(described_class.new).to respond_to(:account)
  end

  it "requires a snapshot date" do
    expect(build(:balance_snapshot, snapshot_on: nil)).not_to be_valid
  end

  describe ".capture_all!" do
    it "captures one row per account that has a balance, skipping NULL balances" do
      with_balance = create(:account, balance_amount: 100)
      create(:account, balance_amount: nil)

      expect { described_class.capture_all! }.to change(described_class, :count).by(1)

      snap = described_class.sole
      expect(snap.account).to eq(with_balance)
      expect(snap.snapshot_on).to eq(Date.current)
      expect(snap.balance_amount).to eq(100)
    end

    # Review B1: the upsert MUST be idempotent — a bare upsert (no unique_by) would
    # raise on this second run instead of updating.
    it "is idempotent — a second run the same day updates in place, never duplicates" do
      account = create(:account, balance_amount: 100)
      described_class.capture_all!

      account.update!(balance_amount: 250)
      expect { described_class.capture_all! }.not_to change(described_class, :count)
      expect(described_class.sole.balance_amount).to eq(250)
    end

    it "captures only the accounts it is given" do
      mine = create(:account, balance_amount: 50)
      create(:account, balance_amount: 90)

      described_class.capture_all!(accounts: Account.where(id: mine.id))

      expect(described_class.pluck(:account_id)).to eq([mine.id])
    end
  end
end
