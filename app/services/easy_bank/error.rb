module EasyBank
  # Base class for all easybank scraper-client errors. Carries the sidecar's HTTP
  # status and machine-readable code where available; the message is safe to
  # surface to the user.
  class Error < StandardError
    attr_reader :status, :code

    def initialize(message = nil, status: nil, code: nil)
      @status = status
      @code = code
      super(message || self.class.name)
    end
  end
end
