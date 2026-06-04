# Daily fan-out for scraped (Trade Republic, easybank) balances. Kept separate
# from SyncAllAccountsJob (the 6h open-banking sync) because scraping runs just
# once a day. Each connection is enqueued with jitter so the fetches don't all
# hit the same upstream at the same instant, and connections that were synced
# recently (e.g. a manual sync) are skipped to avoid duplicate logins. easybank
# is included here too, and is deliberately capped to a 30-day backfill in the
# background (the full 360-day backfill triggers an SMS mTAN — interactive only).
class SyncScrapedBalancesJob < ApplicationJob
  queue_as :default

  RECENCY_WINDOW = 20.hours
  MAX_JITTER = 1.hour

  def perform
    BankConnection.active.where(provider: %w[trade_republic easybank]).find_each do |bc|
      next if bc.last_synced_at && bc.last_synced_at > RECENCY_WINDOW.ago

      SyncAccountsJob.set(wait: rand(0..MAX_JITTER.to_i).seconds).perform_later(bc.id)
    end
  end
end
