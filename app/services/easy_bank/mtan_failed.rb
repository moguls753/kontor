module EasyBank
  # The submitted mTAN was wrong or expired (sidecar 422, body error
  # "mtan_failed"). User-actionable and retryable from the UI — leave the
  # connection in a state the user can retry.
  class MtanFailed < Error; end
end
