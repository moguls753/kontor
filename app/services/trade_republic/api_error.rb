module TradeRepublic
  # Transient upstream failure (sidecar 5xx / unexpected). Retry; never expire
  # the connection. Distinct class from EnableBanking/GoCardless ApiError.
  class ApiError < Error; end
end
