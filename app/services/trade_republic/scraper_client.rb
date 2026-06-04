require "net/http"
require "json"

module TradeRepublic
  # HTTP client for the network-isolated pytr sidecar. Mirrors GoCardless::Client's
  # Net::HTTP style. Read timeouts are deliberately longer than the sidecar's own
  # internal deadlines (balance 90s, pairing 60s) so the sidecar returns a clean
  # transient error first, rather than Rails timing out the socket.
  class ScraperClient
    DEFAULT_URL = "http://tr-scraper:8000"
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 120

    def initialize(base_url: ENV.fetch("SCRAPER_SIDECAR_URL", DEFAULT_URL), token: ENV["SCRAPER_SIDECAR_TOKEN"])
      @base_url = base_url
      @token = token
    end

    # -> { pairing_id:, countdown_seconds:, channel: }
    def pair_start(phone_number:, pin:)
      post("/pairing/start", { phone_no: phone_number, pin: pin })
    end

    # -> { session_blob: }
    def pair_finish(pairing_id:, code:)
      post("/pairing/finish", { pairing_id: pairing_id, code: code })
    end

    # -> { total:, currency:, session_blob:, as_of:, warnings: }
    def balance(phone_number:, session_blob:)
      post("/balance", { phone_no: phone_number, session_blob: session_blob })
    end

    private

    def post(path, body)
      uri = URI("#{@base_url}#{path}")
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["X-Sidecar-Token"] = @token.to_s
      request.body = body.to_json
      execute(uri, request)
    end

    def execute(uri, request)
      response = Net::HTTP.start(
        uri.hostname, uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: OPEN_TIMEOUT,
        read_timeout: READ_TIMEOUT
      ) { |http| http.request(request) }

      handle_response(response)
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError, Net::OpenTimeout, Net::ReadTimeout, EOFError => e
      raise SidecarUnavailableError.new("Trade Republic scraper is unavailable (#{e.class})")
    end

    def handle_response(response)
      status = response.code.to_i
      body = parse(response.body)
      case status
      when 200..299
        body || {}
      when 409
        raise SessionExpiredError.new(body&.dig(:message), status: status, code: body&.dig(:error))
      when 410
        raise PairingExpiredError.new(body&.dig(:message), status: status, code: body&.dig(:error))
      when 422
        raise PairingFailedError.new(body&.dig(:message), status: status, code: body&.dig(:error))
      else
        raise ApiError.new(body&.dig(:message) || "Scraper error #{status}", status: status, code: body&.dig(:error))
      end
    end

    def parse(raw)
      return nil if raw.nil? || raw.empty?

      JSON.parse(raw, symbolize_names: true)
    rescue JSON::ParserError
      nil
    end
  end
end
