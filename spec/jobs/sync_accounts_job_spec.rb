require "rails_helper"

RSpec.describe SyncAccountsJob, type: :job do
  let(:user) { create(:user) }
  let(:eb_client) { instance_double(EnableBanking::Client) }
  let(:gc_client) { instance_double(GoCardless::Client) }
  let(:tr_client) { instance_double(TradeRepublic::ScraperClient) }
  let(:easybank_client) { instance_double(EasyBank::ScraperClient) }

  before do
    allow(EnableBanking::Client).to receive(:new).and_return(eb_client)
    allow(GoCardless::Client).to receive(:new).and_return(gc_client)
    allow(TradeRepublic::ScraperClient).to receive(:new).and_return(tr_client)
    allow(EasyBank::ScraperClient).to receive(:new).and_return(easybank_client)
  end

  it "signs EB amounts by credit_debit_indicator" do
    create(:enable_banking_credential, user: user)
    bc = create(:bank_connection, user: user, provider: "enable_banking")
    account = create(:account, bank_connection: bc)

    allow(eb_client).to receive(:account_balances).and_return(eb_balances_response)
    allow(eb_client).to receive(:account_transactions).and_return(eb_transactions_response)

    described_class.perform_now(bc.id)

    expect(account.transaction_records.find_by(transaction_id: "tx-001").amount).to eq(-42.50)
    expect(account.transaction_records.find_by(transaction_id: "tx-002").amount).to eq(2500.00)
  end

  it "imports GC transactions with pre-signed amounts" do
    create(:go_cardless_credential, :with_token, user: user)
    bc = create(:bank_connection, :gocardless, user: user)
    account = create(:account, bank_connection: bc, iban: "DE111", name: "Test")

    allow(gc_client).to receive(:account_balances).and_return(gc_balances_response)
    allow(gc_client).to receive(:account_transactions).and_return(gc_transactions_response)

    described_class.perform_now(bc.id)

    expect(account.transaction_records.find_by(transaction_id: "gc-tx-001").amount).to eq(-42.50)
    expect(account.transaction_records.find_by(transaction_id: "gc-tx-002").amount).to eq(2500.00)
  end

  it "deduplicates on repeat sync" do
    create(:enable_banking_credential, user: user)
    bc = create(:bank_connection, user: user, provider: "enable_banking")
    account = create(:account, bank_connection: bc)

    allow(eb_client).to receive(:account_balances).and_return(eb_balances_response)
    allow(eb_client).to receive(:account_transactions).and_return(eb_transactions_response)

    2.times { described_class.perform_now(bc.id) }
    expect(account.transaction_records.count).to eq(2)
  end

  it "ingests EB transactions that carry no transaction_id via a synthetic id, idempotently" do
    create(:enable_banking_credential, user: user)
    bc = create(:bank_connection, user: user, provider: "enable_banking")
    account = create(:account, bank_connection: bc)

    allow(eb_client).to receive(:account_balances).and_return(eb_balances_response)
    allow(eb_client).to receive(:account_transactions).and_return(eb_transactions_response_without_ids)

    2.times { described_class.perform_now(bc.id) }

    expect(account.transaction_records.count).to eq(2)
    expect(account.transaction_records.pluck(:transaction_id)).to all(be_present)
    expect(account.transaction_records.pluck(:transaction_id)).to all(start_with("eb-gen-"))
    expect(account.transaction_records.find_by(amount: -31.00)).to be_present
    expect(account.transaction_records.find_by(amount: 428.00)).to be_present
  end

  it "updates an id-less EB tx in place when its mutable fields change, matching on fundamentals" do
    create(:enable_banking_credential, user: user)
    bc = create(:bank_connection, user: user, provider: "enable_banking")
    account = create(:account, bank_connection: bc)

    allow(eb_client).to receive(:account_balances).and_return(eb_balances_response)
    allow(eb_client).to receive(:account_transactions).and_return(
      eb_transactions_response_without_ids, eb_transactions_response_without_ids_mutated
    )

    described_class.perform_now(bc.id)
    described_class.perform_now(bc.id)

    expect(account.transaction_records.count).to eq(2)
    updated = account.transaction_records.find_by(amount: -31.00)
    expect(updated.remittance).to eq("PayPal settled")
    expect(updated.value_date).to eq(Date.new(2026, 6, 4))
  end

  it "keeps two same-day same-amount id-less EB txs as two distinct rows, idempotently" do
    create(:enable_banking_credential, user: user)
    bc = create(:bank_connection, user: user, provider: "enable_banking")
    account = create(:account, bank_connection: bc)

    allow(eb_client).to receive(:account_balances).and_return(eb_balances_response)
    allow(eb_client).to receive(:account_transactions).and_return(eb_transactions_response_same_day_pair)

    2.times { described_class.perform_now(bc.id) }

    expect(account.transaction_records.count).to eq(2)
    expect(account.transaction_records.pluck(:remittance)).to contain_exactly("Spotify", "Netflix")
  end

  it "skips pending EB transactions and normalizes the booked status" do
    create(:enable_banking_credential, user: user)
    bc = create(:bank_connection, user: user, provider: "enable_banking")
    account = create(:account, bank_connection: bc)

    allow(eb_client).to receive(:account_balances).and_return(eb_balances_response)
    allow(eb_client).to receive(:account_transactions).and_return(eb_transactions_response_with_pending)

    described_class.perform_now(bc.id)

    expect(account.transaction_records.count).to eq(1)
    booked = account.transaction_records.find_by(transaction_id: "tx-booked-1")
    expect(booked.status).to eq("booked")
    expect(account.transaction_records.find_by(transaction_id: "tx-pending-1")).to be_nil
  end

  it "keeps syncing sibling accounts when one account hits a non-reauth ASPSP error" do
    create(:enable_banking_credential, user: user)
    bc = create(:bank_connection, user: user, provider: "enable_banking")
    bad = create(:account, bank_connection: bc, account_uid: "uid-bad")
    good = create(:account, bank_connection: bc, account_uid: "uid-good")

    allow(eb_client).to receive(:account_balances).with(account_uid: "uid-bad")
      .and_raise(EnableBanking::ApiError.new(status: 400, body: '{"error":"ASPSP_ERROR"}'))
    allow(eb_client).to receive(:account_balances).with(account_uid: "uid-good")
      .and_return(eb_balances_response)
    allow(eb_client).to receive(:account_transactions).with(hash_including(account_uid: "uid-good"))
      .and_return(eb_transactions_response)

    described_class.perform_now(bc.id)

    expect(good.transaction_records.count).to eq(2)
    expect(bad.transaction_records.count).to eq(0)
    expect(bad.reload.last_synced_at).to be_nil
    expect(bc.reload.status).to eq("authorized")
  end

  it "re-raises an EB 429 so retry_on backs off and the connection stays authorized" do
    create(:enable_banking_credential, user: user)
    bc = create(:bank_connection, user: user, provider: "enable_banking")
    create(:account, bank_connection: bc, account_uid: "uid-1")

    allow(eb_client).to receive(:account_balances)
      .and_raise(EnableBanking::RateLimitError.new(status: 429, body: '{"error":"RATE_LIMIT"}'))

    expect { described_class.perform_now(bc.id) }.to have_enqueued_job(SyncAccountsJob)
    expect(bc.reload.status).to eq("authorized")
    expect(bc.last_synced_at).to be_nil
  end

  it "marks an EB connection expired when a data endpoint reports a reauth (401)" do
    create(:enable_banking_credential, user: user)
    bc = create(:bank_connection, user: user, provider: "enable_banking")
    create(:account, bank_connection: bc, account_uid: "uid-1")

    allow(eb_client).to receive(:account_balances)
      .and_raise(EnableBanking::ApiError.new(status: 401, body: '{"error":"UNAUTHORIZED"}'))

    described_class.perform_now(bc.id)

    expect(bc.reload.status).to eq("expired")
    expect(bc.error_message).to be_present
  end

  it "skips and marks expired EB connections" do
    create(:enable_banking_credential, user: user)
    bc = create(:bank_connection, user: user, provider: "enable_banking", valid_until: 1.day.ago)

    described_class.perform_now(bc.id)
    expect(bc.reload.status).to eq("expired")
  end

  it "marks a GoCardless connection expired when its consent has lapsed (401)" do
    create(:go_cardless_credential, :with_token, user: user)
    bc = create(:bank_connection, :gocardless, user: user)
    create(:account, bank_connection: bc, iban: "DE111", name: "Test")

    allow(gc_client).to receive(:account_balances).and_raise(
      GoCardless::ApiError.new(status: 401, body: '{"summary":"End User Agreement has expired"}')
    )

    described_class.perform_now(bc.id)

    expect(bc.reload.status).to eq("expired")
    expect(bc.error_message).to be_present
  end

  it "updates the Trade Republic balance and persists the refreshed session" do
    cred = create(:trade_republic_credential, :paired, user: user)
    bc = create(:bank_connection, :trade_republic, user: user)
    account = create(:account, bank_connection: bc, account_uid: "trade_republic", name: "Trade Republic")

    allow(tr_client).to receive(:balance).and_return(
      total: "12487.65", currency: "EUR", session_blob: "refreshed-blob", warnings: []
    )

    described_class.perform_now(bc.id)

    expect(account.reload.balance_amount).to eq(BigDecimal("12487.65"))
    expect(cred.reload.session_blob).to eq("refreshed-blob")
    expect(bc.reload.status).to eq("authorized")
  end

  it "marks a Trade Republic connection expired on a session expiry (409)" do
    create(:trade_republic_credential, :paired, user: user)
    bc = create(:bank_connection, :trade_republic, user: user)
    create(:account, bank_connection: bc, account_uid: "trade_republic")

    allow(tr_client).to receive(:balance).and_raise(TradeRepublic::SessionExpiredError.new("expired"))

    described_class.perform_now(bc.id)

    expect(bc.reload.status).to eq("expired")
    expect(bc.error_message).to be_present
  end

  it "does NOT expire on a transient Trade Republic error, and retries instead" do
    create(:trade_republic_credential, :paired, user: user)
    bc = create(:bank_connection, :trade_republic, user: user)
    create(:account, bank_connection: bc, account_uid: "trade_republic")

    allow(tr_client).to receive(:balance).and_raise(TradeRepublic::ApiError.new("upstream down", status: 503))

    expect { described_class.perform_now(bc.id) }.to have_enqueued_job(SyncAccountsJob)
    expect(bc.reload.status).to eq("authorized")
  end

  it "does NOT expire when the scraper sidecar is unreachable, and retries" do
    create(:trade_republic_credential, :paired, user: user)
    bc = create(:bank_connection, :trade_republic, user: user)
    create(:account, bank_connection: bc, account_uid: "trade_republic")

    allow(tr_client).to receive(:balance).and_raise(TradeRepublic::SidecarUnavailableError.new("sidecar down"))

    expect { described_class.perform_now(bc.id) }.to have_enqueued_job(SyncAccountsJob)
    expect(bc.reload.status).to eq("authorized")
  end

  it "does not crash on a blank balance: skips the write but keeps the refreshed session" do
    cred = create(:trade_republic_credential, :paired, user: user)
    bc = create(:bank_connection, :trade_republic, user: user)
    account = create(:account, bank_connection: bc, account_uid: "trade_republic", balance_amount: nil)

    allow(tr_client).to receive(:balance).and_return(total: nil, currency: "EUR", session_blob: "blob2", warnings: [])

    expect { described_class.perform_now(bc.id) }.not_to raise_error
    expect(account.reload.balance_amount).to be_nil
    expect(cred.reload.session_blob).to eq("blob2")
    expect(bc.reload.status).to eq("authorized")
  end

  it "imports easybank transactions with their already-signed amounts, FX and balance/credit fields" do
    create(:easybank_credential, :paired, user: user)
    bc = create(:bank_connection, :easybank, user: user)
    account = create(:account, bank_connection: bc, account_uid: "easybank")

    allow(easybank_client).to receive(:sync).and_return(easybank_sync_response)

    described_class.perform_now(bc.id)

    debit = account.transaction_records.find_by(transaction_id: "eb-tx-001")
    credit = account.transaction_records.find_by(transaction_id: "eb-tx-002")
    expect(debit.amount).to eq(BigDecimal("-26.80"))
    expect(debit.status).to eq("pending")
    expect(debit.creditor_name).to eq("GitHub")
    expect(debit.original_amount).to eq(BigDecimal("-5.95"))
    expect(debit.original_currency).to eq("USD")
    expect(debit.exchange_rate).to eq(BigDecimal("1.162"))
    expect(debit.mcc).to eq("5734")
    expect(credit.amount).to eq(BigDecimal("150.00"))
    expect(credit.status).to eq("booked")

    expect(account.reload.balance_amount).to eq(BigDecimal("-980.31"))
    expect(account.credit_limit).to eq(BigDecimal("4000.00"))
    expect(account.available_credit).to eq(BigDecimal("3019.69"))
    expect(bc.reload.status).to eq("authorized")
  end

  it "always requests a 30-day backfill in the background (never the mTAN-triggering full backfill)" do
    create(:easybank_credential, :paired, user: user)
    bc = create(:bank_connection, :easybank, user: user)
    create(:account, bank_connection: bc, account_uid: "easybank")

    expect(easybank_client).to receive(:sync).with(hash_including(backfill_days: 30)).and_return(easybank_sync_response)

    described_class.perform_now(bc.id)
  end

  it "ingests the easybank payload through the shared EasyBank::Ingest service" do
    create(:easybank_credential, :paired, user: user)
    bc = create(:bank_connection, :easybank, user: user)
    create(:account, bank_connection: bc, account_uid: "easybank")

    allow(easybank_client).to receive(:sync).and_return(easybank_sync_response)
    expect(EasyBank::Ingest).to receive(:call).with(bc, easybank_sync_response).and_call_original

    described_class.perform_now(bc.id)
  end

  it "deduplicates easybank transactions on repeat sync" do
    create(:easybank_credential, :paired, user: user)
    bc = create(:bank_connection, :easybank, user: user)
    account = create(:account, bank_connection: bc, account_uid: "easybank")

    allow(easybank_client).to receive(:sync).and_return(easybank_sync_response)

    2.times { described_class.perform_now(bc.id) }
    expect(account.transaction_records.count).to eq(2)
  end

  it "expires an easybank connection when a background sync comes back needing an mTAN" do
    create(:easybank_credential, :paired, user: user)
    bc = create(:bank_connection, :easybank, user: user)
    create(:account, bank_connection: bc, account_uid: "easybank")

    allow(easybank_client).to receive(:sync).and_return(easybank_sync_response(otp_required: true))

    described_class.perform_now(bc.id)

    expect(bc.reload.status).to eq("expired")
    expect(bc.error_message).to be_present
  end

  it "marks an easybank connection expired on a session expiry (409)" do
    create(:easybank_credential, :paired, user: user)
    bc = create(:bank_connection, :easybank, user: user)
    create(:account, bank_connection: bc, account_uid: "easybank")

    allow(easybank_client).to receive(:sync).and_raise(EasyBank::SessionExpiredError.new("expired"))

    described_class.perform_now(bc.id)

    expect(bc.reload.status).to eq("expired")
    expect(bc.error_message).to be_present
  end

  it "does NOT expire on a transient easybank error, and retries instead" do
    create(:easybank_credential, :paired, user: user)
    bc = create(:bank_connection, :easybank, user: user)
    create(:account, bank_connection: bc, account_uid: "easybank")

    allow(easybank_client).to receive(:sync).and_raise(EasyBank::ApiError.new("upstream down", status: 503))

    expect { described_class.perform_now(bc.id) }.to have_enqueued_job(SyncAccountsJob)
    expect(bc.reload.status).to eq("authorized")
  end
end
