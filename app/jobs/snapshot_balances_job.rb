# Daily snapshot of every account's current balance, so a net-worth-over-time
# series can be reconstructed going forward. A single idempotent upsert pass per
# day (no fan-out). Scheduled in config/recurring.yml; also invoked from
# ProcessAccountDataJob so an intraday manual sync refreshes today's row.
class SnapshotBalancesJob < ApplicationJob
  queue_as :default

  def perform
    BalanceSnapshot.capture_all!
  end
end
