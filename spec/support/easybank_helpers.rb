module EasybankHelpers
  # Mirrors the easybank sidecar's 200 /sync body. String keys (the Rails client
  # parses without symbolizing): money values are SIGNED strings, dates are
  # 'YYYY-MM-DD'. One FX debit and one credit (both booked) so amount signing +
  # the FX fields are exercised, plus one pending row to prove booked-only ingest
  # SKIPS it.
  def easybank_sync_response(otp_required: false)
    {
      "status" => "ok",
      "balance" => { "value" => "-980.31", "currency" => "EUR" },
      "available" => { "value" => "3292.89", "currency" => "EUR" },
      "account" => {
        "iban" => "DE02120300000000202051",
        "number" => "1234",
        "name" => "easybank Kreditkarte",
        "type" => "credit_card",
        "credit_limit" => { "value" => "4000.00", "currency" => "EUR" },
        "available_credit" => { "value" => "3019.69", "currency" => "EUR" }
      },
      "transactions" => [
        {
          "id" => "eb-tx-001",
          "booking_date" => "2026-06-02",
          "value_date" => "2026-06-02",
          "amount" => "-26.80",
          "currency" => "EUR",
          "original_amount" => "-5.95",
          "original_currency" => "USD",
          "exchange_rate" => 1.162,
          "description" => "GITHUB INC",
          "merchant" => "GitHub",
          "mcc" => "5734",
          "is_pending" => false,
          "type" => "Debit"
        },
        {
          "id" => "eb-tx-002",
          "booking_date" => "2026-05-30",
          "value_date" => "2026-05-30",
          "amount" => "150.00",
          "currency" => "EUR",
          "original_amount" => nil,
          "original_currency" => nil,
          "exchange_rate" => nil,
          "description" => "Lastschrifteinzug",
          "merchant" => nil,
          "mcc" => nil,
          "is_pending" => false,
          "type" => "Credit"
        },
        {
          # Pending ('vorgemerkt') — booked-only ingest must SKIP this row, since
          # its ReferenceNumber changes to the ARN on settlement (re-duplicating).
          "id" => "eb-tx-003-pending",
          "booking_date" => "2026-06-03",
          "value_date" => "2026-06-03",
          "amount" => "-9.99",
          "currency" => "EUR",
          "original_amount" => nil,
          "original_currency" => nil,
          "exchange_rate" => nil,
          "description" => "DM DROGERIEMARKT",
          "merchant" => "dm",
          "mcc" => "5912",
          "is_pending" => true,
          "type" => "Debit"
        }
      ],
      "otp_required" => otp_required
    }
  end
end

RSpec.configure do |config|
  config.include EasybankHelpers
end
