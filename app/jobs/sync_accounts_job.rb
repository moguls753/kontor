class SyncAccountsJob < ApplicationJob
  queue_as :default

  retry_on EnableBanking::RateLimitError, wait: 6.hours, attempts: 3
  retry_on GoCardless::RateLimitError, wait: 6.hours, attempts: 3

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
  end

  private

  REAUTH_MESSAGE = "Bank consent has expired. Reconnect this connection to resume syncing."

  def reauth_required?(error)
    [ 401, 403 ].include?(error.status)
  end

  def sync_enable_banking
    credential = @bc.user.enable_banking_credential
    client = EnableBanking::Client.new(app_id: credential.app_id, private_key_pem: credential.private_key_pem)

    @bc.accounts.each do |account|
      sync_eb_balances(client, account)
      sync_eb_transactions(client, account)
      account.update!(last_synced_at: Time.current)
    end
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

  def sync_eb_transactions(client, account)
    date_from = sync_start_date(account)
    date_to = Date.current.iso8601
    continuation_key = nil

    loop do
      data = client.account_transactions(
        account_uid: account.account_uid,
        date_from: date_from,
        date_to: date_to,
        continuation_key: continuation_key
      )

      (data[:transactions] || []).each do |tx|
        upsert_eb_transaction(account, tx)
      end

      continuation_key = data[:continuation_key]
      break if continuation_key.nil?
    end
  end

  def upsert_eb_transaction(account, tx)
    record = account.transaction_records.find_or_initialize_by(transaction_id: tx[:transaction_id])

    amount = BigDecimal(tx[:transaction_amount][:amount])
    amount = -amount if tx[:credit_debit_indicator] == "DBIT"

    record.assign_attributes(
      amount: amount,
      currency: tx[:transaction_amount][:currency],
      booking_date: tx[:booking_date],
      value_date: tx[:value_date],
      status: tx[:status] || "booked",
      remittance: Array(tx[:remittance_information]).join(" "),
      creditor_name: tx.dig(:creditor, :name),
      creditor_iban: tx.dig(:creditor_account, :iban),
      debtor_name: tx.dig(:debtor, :name),
      debtor_iban: tx.dig(:debtor_account, :iban),
      entry_reference: tx[:entry_reference]
    )
    record.save!
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
