class DetectAllRecurringSeriesJob < ApplicationJob
  queue_as :default

  # Scoped to users who actually have transactions — mirrors how
  # SyncAllAccountsJob narrows to active providers rather than iterating
  # everything. Keeps next_expected_on fresh and (phase 2) powers
  # missed-payment alerts. Detection degrades gracefully without an LLM.
  def perform
    User.where(id: BankConnection.joins(accounts: :transaction_records)
                                 .select(:user_id).distinct)
        .find_each do |user|
      # Ordering contract (§3a): match transfers (and commit) before the detector
      # reads transfer_group_id. Idempotent across runs.
      TransferMatcher.new(user).match
      RecurringDetector.new(user).detect
    end
  end
end
