class SyncAllAccountsJob < ApplicationJob
  queue_as :default

  def perform
    # Scraped providers (Trade Republic, easybank) run once a day via
    # SyncScrapedBalancesJob, not on this 6h open-banking cadence. Exclude them
    # here rather than narrowing the shared `active` scope (which other code
    # relies on). PayPal is manual-sync-only (the device push is out-of-band and
    # can't be approved unattended) — it is excluded from BOTH scheduled jobs and
    # never enqueued automatically.
    connections = BankConnection.active.where.not(provider: %w[trade_republic easybank paypal])
    connections.find_each do |bc|
      SyncAccountsJob.perform_later(bc.id)
    end

    # Post-sync pipeline (§3a): categorize → match transfers → detect recurring.
    # Enqueued ONCE per user after the per-connection fan-out (not inside the
    # per-connection SyncAccountsJob, which would fan out N times → races). The
    # job is debounced per user (Solid Queue concurrency, on_conflict: :discard),
    # so several connections finishing together collapse into a single run.
    connections.distinct.pluck(:user_id).each do |user_id|
      ProcessAccountDataJob.perform_later(user_id)
    end
  end
end
