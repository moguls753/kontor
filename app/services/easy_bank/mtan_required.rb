module EasyBank
  # The sidecar needs an mTAN (SMS one-time code) to continue — raised on a 409
  # whose body error is "mtan_required". Not a hard failure: it carries the
  # pairing handle and SMS metadata the frontend needs to prompt for the code,
  # which is then submitted via submit_mtan. Distinct from session_expired (also
  # a 409) — they are told apart by the body error field, NOT the status.
  class MtanRequired < Error
    attr_reader :pairing_id, :masked_phone, :reference, :expires_in

    def initialize(message = nil, status: nil, code: nil, pairing_id: nil, masked_phone: nil, reference: nil, expires_in: nil)
      @pairing_id = pairing_id
      @masked_phone = masked_phone
      @reference = reference
      @expires_in = expires_in
      super(message, status: status, code: code)
    end
  end
end
