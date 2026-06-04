class SyncAllAccountsJob < ApplicationJob
  queue_as :default

  def perform
    # Scraped providers (Trade Republic, easybank) run once a day via
    # SyncScrapedBalancesJob, not on this 6h open-banking cadence. Exclude them
    # here rather than narrowing the shared `active` scope (which other code
    # relies on).
    BankConnection.active.where.not(provider: %w[trade_republic easybank]).find_each do |bc|
      SyncAccountsJob.perform_later(bc.id)
    end
  end
end
