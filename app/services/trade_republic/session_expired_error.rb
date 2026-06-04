module TradeRepublic
  # The saved cookie session is no longer valid (sidecar 409). The connection
  # must be re-paired. A separate class (NOT an ApiError) so the sync job can
  # expire the connection instead of retrying it.
  class SessionExpiredError < Error; end
end
