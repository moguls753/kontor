module EasyBank
  # Persists an easybank sidecar /sync (or resumed /mtan) payload onto the
  # connection's single credit-card account. Shared by the interactive connect
  # flow (BankConnectionsController) and the background SyncAccountsJob so both
  # ingest the sidecar's string-keyed body identically — the only difference
  # between them is *how* the payload was fetched (30-day background sync vs.
  # the one-time ~360-day backfill that resumes through an mTAN).
  #
  # `result` is the raw parsed body (string keys): money values are SIGNED
  # strings, dates are 'YYYY-MM-DD'. Idempotent: the account and every
  # transaction are upserted on their stable ids, so a duplicate page-1 capture
  # on a backfill resume updates in place rather than inserting twice.
  #
  # The booked-only + synthetic-id + per-row-rescue + idempotent transaction
  # upsert lives in ScraperIngestBase (shared with Paypal::Ingest). This subclass
  # adds the easybank-specific account creation / balance + credit updates and the
  # FX columns, which are NOT shared (PayPal has no balance surface here).
  class Ingest < ScraperIngestBase
    # The easybank connection always backs exactly one credit-card account,
    # keyed by a synthetic account_uid (mirrors the controller's
    # ensure_easybank_account so an ingest can run even if no account exists yet,
    # e.g. when the very first connect resumes through an mTAN).
    ACCOUNT_UID = "easybank".freeze

    def self.call(bank_connection, result)
      new(bank_connection, result).call
    end

    def call
      account = ensure_account
      update_account(account)
      ingest_transactions(account)
      account
    end

    private

    def ensure_account
      @bank_connection.accounts.find_or_create_by!(account_uid: ACCOUNT_UID) do |a|
        a.name = @bank_connection.institution_name.presence || "easybank Kreditkarte"
        a.currency = "EUR"
      end
    end

    def update_account(account)
      balance = @result["balance"] || {}
      acct = @result["account"] || {}

      account.update!(
        # Signed string straight from the sidecar (a credit-card balance owed is
        # negative). BigDecimal keeps full precision.
        balance_amount: balance["value"].present? ? BigDecimal(balance["value"]) : account.balance_amount,
        currency: balance["currency"].presence || account.currency,
        balance_type: "expected",
        iban: acct["iban"].presence || account.iban,
        name: acct["name"].presence || account.name,
        account_type: acct["type"].presence || account.account_type,
        credit_limit: money_value(acct["credit_limit"]),
        available_credit: money_value(acct["available_credit"]),
        balance_updated_at: Time.current,
        last_synced_at: Time.current
      )
    end

    # Extend the shared wire mapping with easybank's FX + credit-card columns.
    def transaction_attributes(tx)
      super.merge(
        original_amount: tx["original_amount"].present? ? BigDecimal(tx["original_amount"]) : nil,
        original_currency: tx["original_currency"],
        exchange_rate: tx["exchange_rate"].present? ? BigDecimal(tx["exchange_rate"].to_s) : nil,
        mcc: tx["mcc"]
      )
    end

    # credit_limit / available_credit arrive as { "value", "currency" } objects or
    # null. We only persist the decimal value (currency is the account's).
    def money_value(obj)
      return nil if obj.blank?

      value = obj["value"]
      value.present? ? BigDecimal(value) : nil
    end
  end
end
