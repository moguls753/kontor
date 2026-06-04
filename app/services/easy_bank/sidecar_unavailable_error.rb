module EasyBank
  # The scraper sidecar could not be reached (connection refused, host
  # unreachable, network timeout) or returned a 503. Retry; never expire the
  # connection.
  class SidecarUnavailableError < Error; end
end
