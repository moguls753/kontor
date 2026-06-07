module Paypal
  # Persists a paypal-scraper /sync payload onto the connection's single PayPal
  # account. Shared by nothing but the synchronous manual sync (PayPal is
  # manual-sync-only — no background job). `result` is the raw parsed body
  # (string keys): money values are SIGNED strings, dates are 'YYYY-MM-DD'.
  #
  # PayPal has no account-balance surface in the scrape (the activity list has no
  # running balance), so unlike EasyBank::Ingest there is no update_account — just
  # the shared booked-only + synthetic-id-aware + idempotent transaction upsert
  # from ScraperIngestBase. Re-running a sync is safe: every row upserts on its
  # stable id, so the count stays stable across repeat syncs.
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
  end
end
