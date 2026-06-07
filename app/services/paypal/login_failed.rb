module Paypal
  # Wrong username/password (sidecar 422, body error "login_failed").
  # User-actionable: the stored PayPal credential must be corrected.
  class LoginFailed < Error; end
end
