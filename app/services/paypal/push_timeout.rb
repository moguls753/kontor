module Paypal
  # The out-of-band device push ("Bestätigen Sie Ihre Identität" via the PayPal
  # app) was not approved before the sidecar's PUSH_DEADLINE_S — raised on a 409
  # whose body error is "push_timeout".
  #
  # NON-RETRYABLE on purpose: the push is approved by a human on their phone, so an
  # automatic retry has nothing different to do and would just re-prompt. NEVER
  # register this in any retry_on. The circuit breaker counts it; the UX asks the
  # user to approve the notification and try the sync again.
  class PushTimeout < Error; end
end
