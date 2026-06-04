module EasyBank
  # Wrong username/password (sidecar 422, body error "login_failed").
  # User-actionable: the stored easybank credential must be corrected.
  class LoginFailed < Error; end
end
