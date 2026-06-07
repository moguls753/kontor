module PaypalHelpers
  # Mirrors the paypal-scraper sidecar's 200 /sync body (see paypal-scraper
  # normalize.py's wire contract). String keys (the Rails client parses without
  # symbolizing): money values are SIGNED strings, dates are 'YYYY-MM-DD', and
  # is_pending is always false (the scraper is booked-only). One debit + one
  # credit so amount signing is exercised; one row carries a synthetic
  # "pp-syn-" id (a row PayPal gave no Transaktionscode for).
  def paypal_sync_response(date_from: "2026-05-07", date_to: "2026-06-06", balance: { "amount" => "0.00", "currency" => "EUR" })
    {
      "status" => "ok",
      "date_from" => date_from,
      "date_to" => date_to,
      # The dashboard "PayPal-Guthaben" available balance (best-effort; null when
      # the sidecar couldn't read the card).
      "balance" => balance,
      "transactions" => [
        {
          "id" => "55X63072JY995300U",
          "merchant" => "eBay S.a.r.l.",
          "description" => "Zahlung",
          "amount" => "-8.15",
          "currency" => "EUR",
          "booking_date" => "2026-06-06",
          "is_pending" => false
        },
        {
          "id" => "3AB12345CD678901E",
          "merchant" => "Acme Inc",
          "description" => "Zahlung erhalten",
          "amount" => "79.00",
          "currency" => "EUR",
          "booking_date" => "2026-05-30",
          "is_pending" => false
        },
        {
          # A row with no Transaktionscode -> deterministic synthetic id.
          "id" => "pp-syn-0123456789abcdef0123",
          "merchant" => "Some Shop",
          "description" => "Zahlung",
          "amount" => "-10.60",
          "currency" => "USD",
          "booking_date" => "2026-05-20",
          "is_pending" => false
        }
      ]
    }
  end
end

RSpec.configure do |config|
  config.include PaypalHelpers
end
