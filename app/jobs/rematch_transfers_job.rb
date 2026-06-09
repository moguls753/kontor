# User-wide transfer-matching trigger (§3b). TransferMatcher is user-wide, so it
# must NOT run inside the per-connection SyncAccountsJob (that runs N times for N
# connections → races + redundant work). Instead every ingest path enqueues this
# single user-scoped job once all of a user's accounts are caught up, and it runs
# (and commits) BEFORE the recurring detector and dashboard read the new legs
# (the ordering contract, §3a).
class RematchTransfersJob < ApplicationJob
  queue_as :default

  def perform(user_id)
    user = User.find_by(id: user_id)
    return unless user

    TransferMatcher.new(user).match
  end
end
