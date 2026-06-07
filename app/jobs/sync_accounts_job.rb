class SyncAccountsJob < ApplicationJob
  queue_as :default

  retry_on EnableBanking::RateLimitError, wait: 6.hours, attempts: 3
  retry_on GoCardless::RateLimitError, wait: 6.hours, attempts: 3
  # Trade Republic transient failures: retry, never expire. Safe to register on
  # this shared job because these classes are only ever raised for the TR branch.
  retry_on TradeRepublic::SidecarUnavailableError, wait: 10.minutes, attempts: 3
  retry_on TradeRepublic::ApiError, wait: 10.minutes, attempts: 3
  # easybank transient failures: same policy, same single-branch safety.
  retry_on EasyBank::SidecarUnavailableError, wait: 10.minutes, attempts: 3
  retry_on EasyBank::ApiError, wait: 10.minutes, attempts: 3

  def perform(bank_connection_id)
    @bc = BankConnection.find(bank_connection_id)
    return unless @bc.authorized?

    if @bc.enable_banking? && @bc.valid_until&.past?
      @bc.update!(status: "expired")
      return
    end

    case @bc.provider
    when "enable_banking" then sync_enable_banking
    when "gocardless" then sync_gocardless
    when "trade_republic" then sync_trade_republic
    when "easybank" then sync_easybank
    when "paypal"
      # PayPal is manual-sync-only: the device push is out-of-band and cannot be
      # approved unattended, so a background sync can never succeed. It is excluded
      # from both scheduled fan-outs (SyncAllAccountsJob / SyncScrapedBalancesJob),
      # so reaching here means something enqueued it by mistake. Raise EXPLICITLY
      # rather than fall through to a silent no-op that would stamp last_synced_at
      # and mask the bug.
      raise ArgumentError, "PayPal connections are manual-sync-only (use sync_paypal); they must not be enqueued on SyncAccountsJob"
    end

    @bc.update!(last_synced_at: Time.current)
  rescue EnableBanking::ApiError, GoCardless::ApiError => e
    # A 401/403 from a data endpoint means the bank-level consent (EB session /
    # GC End User Agreement) has lapsed — the token was accepted but access was
    # not. PSD2 consents expire roughly every 90 days, so this is routine. Mark
    # the connection expired (it drops out of the `active` scope and the UI shows
    # a Reconnect prompt) rather than failing the job silently forever.
    raise unless reauth_required?(e)

    @bc.update!(status: "expired", error_message: REAUTH_MESSAGE)
  rescue TradeRepublic::SessionExpiredError
    # The scraped cookie session lapsed (sidecar 409). This is a *different*
    # class than the EB/GC ApiError above and isn't caught by reauth_required?,
    # so it needs its own rescue. Transient TR failures (ApiError /
    # SidecarUnavailableError) are handled by retry_on and never reach here.
    @bc.update!(status: "expired", error_message: TR_REAUTH_MESSAGE)
  rescue EasyBank::SessionExpiredError
    # The scraped easybank session lapsed (sidecar 409 with error
    # "session_expired", or a background sync that came back needing an mTAN —
    # see sync_easybank). Re-pairing is interactive, so expire the connection;
    # transient failures are handled by retry_on and never reach here.
    @bc.update!(status: "expired", error_message: EASYBANK_REAUTH_MESSAGE)
  end

  private

  REAUTH_MESSAGE = "Bank consent has expired. Reconnect this connection to resume syncing."
  TR_REAUTH_MESSAGE = "Trade Republic session expired. Reconnect to re-pair."
  EASYBANK_REAUTH_MESSAGE = "easybank session expired. Reconnect to re-pair."

  def reauth_required?(error)
    [ 401, 403 ].include?(error.status)
  end

  def sync_enable_banking
    credential = @bc.user.enable_banking_credential
    client = EnableBanking::Client.new(app_id: credential.app_id, private_key_pem: credential.private_key_pem)

    @bc.accounts.each { |account| sync_eb_account(client, account) }
  end

  # A single account's ASPSP-side failure (e.g. a 400 ASPSP_ERROR from a stale
  # or flaky account) must not abort its siblings or fail the whole connection.
  # A consent-level reauth (401/403) still propagates so #perform's rescue marks
  # the connection expired; any other ApiError is logged and skipped so the
  # remaining accounts still sync.
  def sync_eb_account(client, account)
    sync_eb_balances(client, account)
    sync_eb_transactions(client, account)
    account.update!(last_synced_at: Time.current)
  rescue EnableBanking::ApiError => e
    # Reauth (401/403) and rate-limit (429) must reach the JOB-level handlers:
    # the outer rescue expires the connection on reauth, and retry_on backs off
    # on RateLimitError. Only a per-account ASPSP error (e.g. 400) is swallowed
    # here so sibling accounts still sync.
    raise if reauth_required?(e) || e.is_a?(EnableBanking::RateLimitError)

    Rails.logger.warn("EnableBanking sync skipped account ##{account.id} (HTTP #{e.status})")
  end

  def sync_gocardless
    credential = @bc.user.go_cardless_credential
    client = GoCardless::Client.new(credential)

    @bc.accounts.each do |account|
      sync_gc_details(client, account)
      sync_gc_balances(client, account)
      sync_gc_transactions(client, account)
      account.update!(last_synced_at: Time.current)
    end
  end

  # Balance-only: fetch the single total from the scraper sidecar and persist the
  # refreshed cookie session. No transactions. A 409 surfaces as
  # TradeRepublic::SessionExpiredError (handled in the rescue above); transient
  # failures are retried via retry_on and never expire the connection.
  def sync_trade_republic
    credential = @bc.user.trade_republic_credential
    account = @bc.accounts.first
    return unless credential && account

    result = scraper_client.balance(
      phone_number: credential.phone_number,
      session_blob: credential.session_blob
    )

    # Persist the refreshed cookie session first, so a flaky balance line never
    # costs us the (more valuable) renewed session.
    credential.update!(session_blob: result[:session_blob]) if result[:session_blob].present?

    # Defensive: a 200 with a blank total would otherwise raise and dead-letter
    # the job (it is neither a SessionExpired nor a retryable error). Skip the
    # write instead — the next daily run retries. A healthy sidecar always
    # returns a canonical decimal string.
    total = result[:total]
    return if total.blank?

    account.update!(
      balance_amount: BigDecimal(total.to_s),
      currency: result[:currency].presence || "EUR",
      balance_type: "expected",
      balance_updated_at: Time.current,
      last_synced_at: Time.current
    )
  end

  def scraper_client
    @scraper_client ||= TradeRepublic::ScraperClient.new
  end

  # --- easybank ---

  # Full sync (balance + transactions) for the single credit-card account via the
  # easybank sidecar. ALWAYS backfill_days: 30 here — the 360-day backfill triggers
  # an SMS mTAN and must NEVER run unattended; it happens only at interactive
  # connect. A 409 session_expired surfaces as EasyBank::SessionExpiredError
  # (handled in the rescue above); transient failures are retried via retry_on.
  def sync_easybank
    credential = @bc.user.easybank_credential
    account = @bc.accounts.first
    return unless credential && account

    result = easybank_scraper_client.sync(
      username: credential.username,
      password: credential.password,
      backfill_days: EasyBank::ScraperClient::SHORT_BACKFILL_DAYS
    )

    # The background job cannot prompt for an mTAN. If the sidecar signals one is
    # needed, treat it like an expired session: the user must reconnect (where the
    # interactive mTAN flow lives). Raised so the rescue arm expires the connection.
    raise EasyBank::SessionExpiredError.new("mTAN required — reconnect to re-pair") if result["otp_required"]

    # Persist balance + transactions via the shared ingest service (same code the
    # interactive connect/confirm path uses, so behavior stays identical).
    EasyBank::Ingest.call(@bc, result)
  end

  def easybank_scraper_client
    @easybank_scraper_client ||= EasyBank::ScraperClient.new
  end

  # --- Enable Banking ---

  def sync_eb_balances(client, account)
    data = client.account_balances(account_uid: account.account_uid)
    balance = data[:balances]&.first
    return unless balance

    account.update!(
      balance_amount: BigDecimal(balance[:balance_amount][:amount]),
      currency: balance[:balance_amount][:currency],
      balance_type: balance[:balance_type],
      balance_updated_at: Time.current
    )
  end

  # Collect ALL pages first, then hand the whole batch to the ingest service.
  # Fundamental matching (for rows with no transaction_id / entry_reference) needs
  # the complete batch to claim-track, so two identical rows can't both match the
  # same existing row — see EnableBanking::TransactionIngest.
  def sync_eb_transactions(client, account)
    date_from = sync_start_date(account)
    date_to = Date.current.iso8601
    continuation_key = nil
    transactions = []

    loop do
      data = client.account_transactions(
        account_uid: account.account_uid,
        date_from: date_from,
        date_to: date_to,
        continuation_key: continuation_key
      )

      transactions.concat(data[:transactions] || [])

      continuation_key = data[:continuation_key]
      break if continuation_key.nil?
    end

    EnableBanking::TransactionIngest.call(account, transactions)
  end

  # --- GoCardless ---

  def sync_gc_details(client, account)
    return if account.iban.present? && account.name.present?

    data = client.account_details(account_id: account.account_uid)
    details = data[:account]
    return unless details

    account.update!(
      iban: details[:iban] || account.iban,
      name: details[:ownerName] || account.name,
      currency: details[:currency] || account.currency
    )
  end

  def sync_gc_balances(client, account)
    data = client.account_balances(account_id: account.account_uid)
    balance = data[:balances]&.first
    return unless balance

    account.update!(
      balance_amount: BigDecimal(balance[:balanceAmount][:amount]),
      currency: balance[:balanceAmount][:currency],
      balance_type: balance[:balanceType],
      balance_updated_at: Time.current
    )
  end

  def sync_gc_transactions(client, account)
    date_from = sync_start_date(account)
    date_to = Date.current.iso8601

    data = client.account_transactions(
      account_id: account.account_uid,
      date_from: date_from,
      date_to: date_to
    )

    transactions = data.dig(:transactions, :booked) || []
    transactions.each { |tx| upsert_gc_transaction(account, tx) }
  end

  def upsert_gc_transaction(account, tx)
    tid = tx[:internalTransactionId] || tx[:transactionId]
    record = account.transaction_records.find_or_initialize_by(transaction_id: tid)

    record.assign_attributes(
      amount: BigDecimal(tx[:transactionAmount][:amount]),
      currency: tx[:transactionAmount][:currency],
      booking_date: tx[:bookingDate],
      value_date: tx[:valueDate],
      status: "booked",
      remittance: tx[:remittanceInformationUnstructured],
      creditor_name: tx[:creditorName],
      creditor_iban: tx.dig(:creditorAccount, :iban),
      debtor_name: tx[:debtorName],
      debtor_iban: tx.dig(:debtorAccount, :iban),
      bank_transaction_code: tx[:proprietaryBankTransactionCode]
    )
    record.save!
  end

  # --- Shared ---

  def sync_start_date(account)
    last_tx = account.transaction_records.order(booking_date: :desc).pick(:booking_date)
    if last_tx
      (last_tx - 2.days).iso8601
    else
      90.days.ago.to_date.iso8601
    end
  end
end
