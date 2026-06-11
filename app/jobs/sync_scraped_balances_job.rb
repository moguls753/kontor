# Daily fan-out for scraped balances. Only easybank rides this job: it logs in
# with username+password and the bank does NOT challenge an mTAN on the routine
# 30-day sync, so it refreshes unattended. Each connection is enqueued with jitter
# so the fetches don't all hit the upstream at the same instant, and connections
# synced recently (e.g. a manual sync) are skipped to avoid duplicate logins. The
# 30-day cap matters: the full 360-day backfill triggers an SMS mTAN and is
# interactive-only (SyncAccountsJob passes SHORT_BACKFILL_DAYS here).
#
# Trade Republic is deliberately EXCLUDED — like PayPal. Its scraped session does
# not persist between syncs, so every sync needs a fresh app-push 2FA code that
# nobody can enter unattended. A scheduled TR sync could therefore only ever hit
# the dead session and flip the connection to "expired" (futile churn), never
# refresh it. TR stays manual-only: it is synced on demand by SyncAccountsJob
# right after a successful interactive re-pair (confirm_2fa).
class SyncScrapedBalancesJob < ApplicationJob
  queue_as :default

  RECENCY_WINDOW = 20.hours
  MAX_JITTER = 1.hour

  def perform
    enqueued_user_ids = Set.new

    BankConnection.active.where(provider: %w[easybank]).find_each do |bc|
      next if bc.last_synced_at && bc.last_synced_at > RECENCY_WINDOW.ago

      SyncAccountsJob.set(wait: rand(0..MAX_JITTER.to_i).seconds).perform_later(bc.id)
      enqueued_user_ids << bc.user_id
    end

    # Post-sync pipeline (§3a): categorize → match transfers → detect recurring.
    # One run per user whose scraped connection was (re)synced, debounced per user
    # via the job's Solid Queue concurrency control (on_conflict: :discard).
    enqueued_user_ids.each { |user_id| ProcessAccountDataJob.perform_later(user_id) }
  end
end
