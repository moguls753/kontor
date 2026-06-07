module Paypal
  # Persists a paypal-scraper /sync payload onto the connection's single PayPal
  # account. Shared by nothing but the synchronous manual sync (PayPal is
  # manual-sync-only — no background job). `result` is the raw parsed body
  # (string keys): money values are SIGNED strings, dates are 'YYYY-MM-DD'.
  #
  # The activity list has no running balance, but the post-login dashboard carries
  # a "PayPal-Guthaben" card (the available Guthaben). The sidecar reads it
  # best-effort and emits `result["balance"] = {amount, currency} | null`; we set
  # the account's available balance from it when present, and leave the stored
  # balance untouched when it's null (so a one-off scrape miss doesn't zero the
  # dashboard). Otherwise this is just the shared booked-only + synthetic-id-aware
  # + idempotent transaction upsert from ScraperIngestBase. Re-running a sync is
  # safe: every row upserts on its stable id, so the count stays stable across
  # repeat syncs.
  #
  # DEFERRED (accepted §10.3 limitation): FX rows are booked in their foreign
  # currency (e.g. amount in USD, currency "USD") because the activity list shows
  # only the foreign figure — there is no EUR amount without the forbidden inline
  # XHR. Such rows therefore pollute any naive EUR dashboard total. Accepted for
  # v1; revisit if/when FX-aware totals are added.
  class Ingest < ScraperIngestBase
    # The PayPal connection always backs exactly one account, keyed by a synthetic
    # account_uid (mirrors EasyBank::Ingest::ACCOUNT_UID so an ingest can run even
    # if no account exists yet, e.g. on the very first sync).
    ACCOUNT_UID = "paypal".freeze

    def self.call(bank_connection, result)
      new(bank_connection, result).call
    end

    def call
      account = ensure_account
      ingest_transactions(account)
      update_balance(account)
      account.update!(last_synced_at: Time.current)
      account
    end

    private

    def ensure_account
      @bank_connection.accounts.find_or_create_by!(account_uid: ACCOUNT_UID) do |a|
        a.name = @bank_connection.institution_name.presence || "PayPal"
        a.currency = "EUR"
      end
    end

    # Set the account's available balance from the dashboard "PayPal-Guthaben"
    # card. The sidecar parsed it best-effort; a null balance (card absent or
    # unparseable) leaves the stored balance untouched so a one-off scrape miss
    # doesn't blank the dashboard. The amount is a signed Decimal string.
    def update_balance(account)
      balance = @result["balance"]
      return if balance.blank?
      return if balance["amount"].blank?

      account.update!(
        balance_amount: BigDecimal(balance["amount"]),
        currency: balance["currency"].presence || account.currency,
        balance_type: "available",
        balance_updated_at: Time.current
      )
    end
  end
end
