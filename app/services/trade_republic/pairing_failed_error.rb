module TradeRepublic
  # User-actionable pairing failure: wrong phone/PIN, or a wrong/expired 2FA
  # code (sidecar 422). Retryable from the UI.
  class PairingFailedError < Error; end
end
