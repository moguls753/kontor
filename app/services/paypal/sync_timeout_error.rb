module Paypal
  # The /sync request reached the sidecar and the socket then timed out waiting
  # for the response (Net::ReadTimeout / EOFError mid-flight). Unlike
  # SidecarUnavailableError (connection refused / host unreachable / open
  # timeout — the sidecar was never reached, so NO login happened), a read
  # timeout means the sidecar accepted the request and was already driving the
  # browser: a real PayPal login almost certainly fired. We must therefore NOT
  # roll back the rate-limit stamp — doing so would let the user immediately
  # re-sync and burst logins into PayPal's velocity scoring (the captcha we work
  # to avoid). Transient: don't expire the connection or trip the breaker.
  class SyncTimeoutError < Error; end
end
