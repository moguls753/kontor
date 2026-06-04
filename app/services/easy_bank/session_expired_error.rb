module EasyBank
  # The sidecar's saved login session is no longer valid — raised on a 409 whose
  # body error is "session_expired" (told apart from mtan_required by the body,
  # NOT the status). A separate class (NOT an ApiError) so the sync job can expire
  # the connection instead of retrying it, mirroring TradeRepublic::SessionExpiredError.
  class SessionExpiredError < Error; end
end
