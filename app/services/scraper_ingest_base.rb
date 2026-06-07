# Shared transaction-upsert core for the scraper sidecars (easybank, PayPal).
#
# This is ONLY the booked-only + synthetic-id-aware + per-row-rescue + idempotent
# transaction upsert — the part both sidecars do identically. It deliberately does
# NOT include account creation or balance/credit updates (those are easybank
# credit-card-balance logic; PayPal has no account balance surface here). A
# subclass provides the account and may override #upsert_transaction for
# provider-specific column mapping; the default mapping matches the wire contract
# both sidecars emit:
#
#   {id, merchant, description, amount, currency, booking_date, is_pending}
#
# `result` is the raw parsed sidecar body (string keys): money values are SIGNED
# strings, dates are 'YYYY-MM-DD'. Idempotent: every transaction is upserted on
# its stable id (find_or_initialize_by transaction_id), so a duplicate capture
# updates in place rather than inserting twice.
class ScraperIngestBase
  def initialize(bank_connection, result)
    @bank_connection = bank_connection
    @result = result || {}
  end

  private

  # Upsert every BOOKED transaction in the payload onto `account`, with a per-row
  # rescue so one malformed row never aborts the whole batch (which would leave a
  # partial, un-retryable import). Never logs row content (amounts / PII).
  def ingest_transactions(account)
    skipped = 0
    (@result["transactions"] || []).each do |tx|
      # Booked-only: pending rows carry an ephemeral id that changes on
      # settlement, so storing them would re-duplicate at the pending->booked
      # transition. Skip them; only booked rows are persisted.
      next if tx["is_pending"]

      upsert_transaction(account, tx)
    rescue StandardError => e
      skipped += 1
      Rails.logger.warn("#{self.class.name} skipped a transaction (#{e.class})")
    end
    Rails.logger.warn("#{self.class.name} skipped #{skipped} transaction(s)") if skipped.positive?
  end

  # find_or_initialize on the sidecar's stable id keeps this idempotent — a
  # duplicate capture updates in place rather than inserting twice. Degenerate
  # rows (no stable id, or no usable date) can't be deduped/stored — raise so the
  # caller's per-row rescue skips them rather than aborting the batch.
  def upsert_transaction(account, tx)
    raise ArgumentError, "transaction has no id" if tx["id"].blank?
    raise ArgumentError, "transaction has no booking_date" if tx["booking_date"].blank?

    record = account.transaction_records.find_or_initialize_by(transaction_id: tx["id"])
    record.assign_attributes(transaction_attributes(tx))
    record.save!
  end

  # The wire mapping shared by both sidecars. A subclass may extend this for
  # provider-specific columns (e.g. easybank's FX/credit-card fields).
  def transaction_attributes(tx)
    {
      amount: BigDecimal(tx["amount"]), # already SIGNED (debit negative, credit positive)
      currency: tx["currency"],
      booking_date: Date.parse(tx["booking_date"]),
      value_date: tx["value_date"].present? ? Date.parse(tx["value_date"]) : nil,
      # Booked-only ingest: pending rows are skipped in #ingest_transactions, so
      # every row that reaches here is booked.
      status: "booked",
      remittance: tx["description"],
      # The LLM categorizer reads remittance + creditor_name — surface the
      # merchant there so purchases get a usable categorization signal.
      creditor_name: tx["merchant"]
    }
  end
end
