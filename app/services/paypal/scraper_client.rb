require "net/http"
require "json"

module Paypal
  # HTTP client for the network-isolated paypal-scraper sidecar. Mirrors
  # EasyBank::ScraperClient's Net::HTTP style and X-Sidecar-Token auth.
  #
  # Unlike easybank there is no /login + /mtan split: the PayPal device push is
  # out-of-band (approved on the phone), so the sidecar does the whole login +
  # push-block + scrape inside ONE blocking /sync call. We branch on the body's
  # `error` field to distinguish the two NON-RETRYABLE outcomes (captcha_blocked,
  # push_timeout) from the retryable transient ones.
  #
  # Read timeout is deliberately LONGER than the sidecar's own SYNC_DEADLINE_S
  # (~250s) so the sidecar returns a clean push_timeout/transient first rather
  # than Rails timing out the socket — see PAYPAL_SCRAPER_PLAN.md §10.7. The push
  # wait is NON-additive (bounded by the remaining sidecar budget), so the budget
  # must clear PUSH + login-nav + scrape, not just PUSH:
  #   PUSH_DEADLINE_S(150) < sidecar SYNC_DEADLINE_S(250) < Rails READ_TIMEOUT(280) < Thruster(300)
  class ScraperClient
    DEFAULT_URL = "http://paypal-scraper:8000".freeze
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 280

    def initialize(base_url: ENV.fetch("PAYPAL_SIDECAR_URL", DEFAULT_URL), token: ENV["PAYPAL_SIDECAR_TOKEN"])
      @base_url = base_url
      @token = token
    end

    # One blocking call: log in, block on the out-of-band device push, scrape the
    # activity list. date_from / date_to are ISO 'YYYY-MM-DD'; both optional (the
    # sidecar defaults to the last 30 days). -> parsed body hash (string keys).
    def sync(username:, password:, date_from: nil, date_to: nil)
      body = { username: username, password: password }
      body[:date_from] = date_from if date_from
      body[:date_to] = date_to if date_to
      post("/sync", body)
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
      raise SidecarUnavailableError.new("paypal scraper is unavailable (#{e.class})")
    end

    def handle_response(response)
      status = response.code.to_i
      body = parse(response.body) || {}
      error = body["error"]

      case status
      when 200..299
        body
      when 409
        # Device push not approved in time. NON-RETRYABLE: a human approves it.
        raise PushTimeout.new(body["message"], status: status, code: error)
      when 422
        case error
        when "captcha_blocked"
          # Security check we can't solve. NON-RETRYABLE: never auto-retry.
          raise CaptchaBlocked.new(body["message"], status: status, code: error)
        when "login_failed"
          raise LoginFailed.new(body["message"], status: status, code: error)
        when "invalid_request"
          # Our request body was rejected — a contract bug, not a transient fault.
          # Distinct, non-retryable; do NOT collapse it into scraper_unavailable.
          raise InvalidRequestError.new(
            body["message"] || "PayPal scraper rejected the request.",
            status: status, code: error
          )
        else # anything unmapped at 422 — treat as transient/unexpected
          raise ApiError.new(body["message"] || "Scraper error #{status}", status: status, code: error)
        end
      when 503
        raise SidecarUnavailableError.new(body["message"] || "paypal scraper is unavailable", status: status, code: error)
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
