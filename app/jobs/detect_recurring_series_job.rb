class DetectRecurringSeriesJob < ApplicationJob
  queue_as :default

  def perform(user_id)
    user = User.find(user_id)
    # Ordering contract (§3a): the transfer matcher writes transfer_group_id, which
    # the detector reads. Run it synchronously and let it commit BEFORE detection so
    # the detector never sees an un-matched leg. Idempotent — re-running is a no-op
    # for already-paired legs.
    TransferMatcher.new(user).match
    RecurringDetector.new(user).detect
  end
end
