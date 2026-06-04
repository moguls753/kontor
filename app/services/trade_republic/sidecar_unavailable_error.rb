module TradeRepublic
  # The scraper sidecar could not be reached (connection refused, host
  # unreachable, network timeout). Retry; never expire the connection.
  class SidecarUnavailableError < Error; end
end
