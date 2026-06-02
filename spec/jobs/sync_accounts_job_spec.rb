require "rails_helper"

RSpec.describe SyncAccountsJob, type: :job do
  let(:user) { create(:user) }
  let(:eb_client) { instance_double(EnableBanking::Client) }
  let(:gc_client) { instance_double(GoCardless::Client) }

  before do
    allow(EnableBanking::Client).to receive(:new).and_return(eb_client)
    allow(GoCardless::Client).to receive(:new).and_return(gc_client)
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
end
