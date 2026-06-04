module TradeRepublic
  # The in-flight pairing is gone (sidecar 410): its 5-minute TTL elapsed or the
  # sidecar restarted. The user must restart pairing to get a fresh code.
  class PairingExpiredError < Error; end
end
