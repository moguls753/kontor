module Paypal
  # Transient upstream failure or an unexpected/unmapped sidecar response (e.g. a
  # 422 invalid_request, or any other non-2xx). Retry; never expire the
  # connection. Distinct class from the other providers' ApiError.
  class ApiError < Error; end
end
