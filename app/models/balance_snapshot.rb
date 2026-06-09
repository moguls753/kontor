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
class BalanceSnapshot < ApplicationRecord
  belongs_to :account

  validates :snapshot_on, presence: true

  # Idempotent daily capture of each account's current balance, so a
  # net-worth-over-time series can be reconstructed going forward. One row per
  # (account, day), updated in place when captured again the same day.
  #
  # MUST upsert with `unique_by:` the composite index. A bare `upsert`/`upsert_all`
  # without it targets the PRIMARY KEY for ON CONFLICT; with no id supplied it never
  # conflicts on id, then violates the (account_id, snapshot_on) unique index and
  # RAISES on the second run of the day. With unique_by the index backs ON CONFLICT
  # and the capture is genuinely idempotent. Returns the number of rows captured.
  def self.capture_all!(accounts: Account.all, on: Date.current)
    rows = accounts.where.not(balance_amount: nil).map do |account|
      {
        account_id: account.id,
        snapshot_on: on,
        balance_amount: account.balance_amount,
        currency: account.currency
      }
    end
    return 0 if rows.empty?

    upsert_all(rows, unique_by: %i[account_id snapshot_on])
    rows.size
  end
end
