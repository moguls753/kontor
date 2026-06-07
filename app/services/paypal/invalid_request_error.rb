module Paypal
  # The sidecar rejected our /sync request body (422 invalid_request). This is a
  # request/contract bug on our side, NOT a transient upstream fault — retrying
  # the same request will fail identically, so it is kept DISTINCT from ApiError /
  # SidecarUnavailableError and must never be registered in any retry_on.
  class InvalidRequestError < Error; end
end
