require "net/http"
require "json"

module EasyBank
  # HTTP client for the network-isolated easybank-scraper sidecar. Mirrors
  # TradeRepublic::ScraperClient's Net::HTTP style and X-Sidecar-Token auth.
  #
  # The HTTP taxonomy differs from Trade Republic in one important way: the
  # easybank sidecar overloads 409 for two distinct outcomes — an mTAN challenge
  # (continue the flow) and an expired session (re-pair) — and 422 for several
  # validation failures. We therefore branch on the body's `error` field, NOT on
  # the status alone (TR uses 409 vs 410 by status — deliberately NOT copied).
  #
  # Read timeout is deliberately long: a 360-day backfill at interactive connect
  # can take a while, so let the sidecar return a clean transient error first
  # rather than Rails timing out the socket.
  class ScraperClient
    DEFAULT_URL = "http://easybank-scraper:8000"
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 120

    # Mirrors the sidecar's BACKFILL_LONG_DAYS: the one-time deep history range
    # requested only at the first interactive connect. >= 360 makes the sidecar
    # select the long range, which is gated behind an SMS mTAN (raises
    # MtanRequired) — so this MUST never be requested unattended.
    LONG_BACKFILL_DAYS = 360
    # The routine range used everywhere else (background syncs, reconnects).
    SHORT_BACKFILL_DAYS = 30

    def initialize(base_url: ENV.fetch("EASYBANK_SIDECAR_URL", DEFAULT_URL), token: ENV["EASYBANK_SIDECAR_TOKEN"])
      @base_url = base_url
      @token = token
    end

    # Start the login. On a fully device-paired profile the sidecar returns the
    # full sync payload (200) directly; otherwise it raises MtanRequired (409).
    # -> parsed body hash (string keys)
    def login(username:, password:)
      post("/login", { username: username, password: password })
    end

    # Submit the SMS one-time code to finish device pairing.
    # -> parsed body hash (string keys)
    def submit_mtan(pairing_id:, code:)
      post("/mtan", { pairing_id: pairing_id, code: code })
    end

    # Fetch balance + transactions for an already-paired profile. backfill_days
    # defaults to the sidecar's own default (30); the 360-day backfill is only ever
    # requested at interactive connect because it triggers an SMS mTAN.
    # -> parsed body hash (string keys)
    def sync(username:, password:, backfill_days: SHORT_BACKFILL_DAYS)
      post("/sync", { username: username, password: password, backfill_days: backfill_days })
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
      raise SidecarUnavailableError.new("easybank scraper is unavailable (#{e.class})")
    end

    def handle_response(response)
      status = response.code.to_i
      body = parse(response.body) || {}
      error = body["error"]

      case status
      when 200..299
        body
      when 409
        # 409 is overloaded: distinguish on the body, not the status.
        if error == "mtan_required"
          raise MtanRequired.new(
            body["message"],
            status: status, code: error,
            pairing_id: body["pairing_id"],
            masked_phone: body["masked_phone"],
            reference: body["reference"],
            expires_in: body["expires_in"]
          )
        else # "session_expired"
          raise SessionExpiredError.new(body["message"], status: status, code: error)
        end
      when 422
        case error
        when "mtan_failed" then raise MtanFailed.new(body["message"], status: status, code: error)
        when "login_failed" then raise LoginFailed.new(body["message"], status: status, code: error)
        else # "invalid_request" or anything unmapped — transient/unexpected
          raise ApiError.new(body["message"] || "Scraper error #{status}", status: status, code: error)
        end
      when 503
        raise SidecarUnavailableError.new(body["message"] || "easybank scraper is unavailable", status: status, code: error)
      else
        raise ApiError.new(body["message"] || "Scraper error #{status}", status: status, code: error)
      end
    end

    def parse(raw)
      return nil if raw.nil? || raw.empty?

      JSON.parse(raw)
    rescue JSON::ParserError
      nil
    end
  end
end
