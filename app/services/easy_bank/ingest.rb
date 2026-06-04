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
  class Ingest
    # The easybank connection always backs exactly one credit-card account,
    # keyed by a synthetic account_uid (mirrors the controller's
    # ensure_easybank_account so an ingest can run even if no account exists yet,
    # e.g. when the very first connect resumes through an mTAN).
    ACCOUNT_UID = "easybank".freeze

    def self.call(bank_connection, result)
      new(bank_connection, result).call
    end

    def initialize(bank_connection, result)
      @bank_connection = bank_connection
      @result = result || {}
    end

    def call
      account = ensure_account
      update_account(account)

      (@result["transactions"] || []).each do |tx|
        upsert_transaction(account, tx)
      end

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

    # find_or_initialize on the sidecar's stable id keeps this idempotent — a
    # duplicate page-1 capture on a backfill resume updates in place rather than
    # inserting twice. Mirrors upsert_eb_transaction's shape/SAVE behavior.
    def upsert_transaction(account, tx)
      record = account.transaction_records.find_or_initialize_by(transaction_id: tx["id"])

      record.assign_attributes(
        amount: BigDecimal(tx["amount"]), # already SIGNED (Debit negative, Credit positive)
        currency: tx["currency"],
        booking_date: Date.parse(tx["booking_date"]),
        value_date: tx["value_date"].present? ? Date.parse(tx["value_date"]) : nil,
        status: tx["is_pending"] ? "pending" : "booked",
        remittance: tx["description"],
        # The LLM categorizer reads remittance + creditor_name — surface the merchant
        # there so card purchases get a usable categorization signal.
        creditor_name: tx["merchant"],
        original_amount: tx["original_amount"].present? ? BigDecimal(tx["original_amount"]) : nil,
        original_currency: tx["original_currency"],
        exchange_rate: tx["exchange_rate"].present? ? BigDecimal(tx["exchange_rate"].to_s) : nil,
        mcc: tx["mcc"]
      )
      record.save!
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
