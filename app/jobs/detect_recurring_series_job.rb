class DetectRecurringSeriesJob < ApplicationJob
  queue_as :default

  def perform(user_id)
    RecurringDetector.new(User.find(user_id)).detect
  end
end
