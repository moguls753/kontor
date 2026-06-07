module Paypal
  # PayPal showed a security check (reCAPTCHA / "Sicherheitsüberprüfung") that the
  # sidecar cannot solve — raised on a 422 whose body error is "captcha_blocked".
  #
  # NON-RETRYABLE on purpose: re-driving the login immediately would only burn
  # another login attempt against PayPal's velocity scoring and make matters
  # worse. NEVER register this in any retry_on. The circuit breaker counts it; the
  # graceful-degradation UX is "PayPal couldn't sync — try again later."
  class CaptchaBlocked < Error; end
end
