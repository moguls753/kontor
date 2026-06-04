require "rails_helper"

RSpec.describe EasyBank::Ingest do
  let(:user) { create(:user) }
  let(:bank_connection) { create(:bank_connection, :easybank, user: user) }

  describe ".call" do
    it "creates the single easybank account when none exists yet" do
      expect {
        described_class.call(bank_connection, easybank_sync_response)
      }.to change { bank_connection.accounts.count }.from(0).to(1)

      account = bank_connection.accounts.find_by(account_uid: "easybank")
      expect(account.name).to eq("easybank Kreditkarte")
    end

    it "upserts the balance and credit fields onto the account" do
      account = described_class.call(bank_connection, easybank_sync_response)

      expect(account.balance_amount).to eq(BigDecimal("-980.31"))
      expect(account.balance_type).to eq("expected")
      expect(account.currency).to eq("EUR")
      expect(account.iban).to eq("DE02120300000000202051")
      expect(account.account_type).to eq("credit_card")
      expect(account.credit_limit).to eq(BigDecimal("4000.00"))
      expect(account.available_credit).to eq(BigDecimal("3019.69"))
      expect(account.balance_updated_at).to be_present
      expect(account.last_synced_at).to be_present
    end

    it "upserts transactions with signed amounts, FX fields and status mapping" do
      described_class.call(bank_connection, easybank_sync_response)

      account = bank_connection.accounts.find_by(account_uid: "easybank")
      debit = account.transaction_records.find_by(transaction_id: "eb-tx-001")
      credit = account.transaction_records.find_by(transaction_id: "eb-tx-002")

      expect(debit.amount).to eq(BigDecimal("-26.80"))
      expect(debit.status).to eq("pending")
      expect(debit.remittance).to eq("GITHUB INC")
      expect(debit.creditor_name).to eq("GitHub")
      expect(debit.original_amount).to eq(BigDecimal("-5.95"))
      expect(debit.original_currency).to eq("USD")
      expect(debit.exchange_rate).to eq(BigDecimal("1.162"))
      expect(debit.mcc).to eq("5734")
      expect(debit.value_date).to eq(Date.new(2026, 6, 2))

      expect(credit.amount).to eq(BigDecimal("150.00"))
      expect(credit.status).to eq("booked")
      expect(credit.original_amount).to be_nil
      expect(credit.exchange_rate).to be_nil
    end

    it "deduplicates on transaction_id across repeat ingests" do
      2.times { described_class.call(bank_connection, easybank_sync_response) }

      account = bank_connection.accounts.find_by(account_uid: "easybank")
      expect(account.transaction_records.count).to eq(2)
    end

    it "skips malformed rows (missing id or date) without aborting the batch" do
      good = easybank_sync_response["transactions"][1] # eb-tx-002
      result = easybank_sync_response.merge("transactions" => [
        { "id" => nil, "booking_date" => "2026-05-01", "amount" => "-1.00", "currency" => "EUR" },
        good,
        { "id" => "eb-tx-099", "booking_date" => nil, "amount" => "-2.00", "currency" => "EUR" }
      ])

      account = nil
      expect { account = described_class.call(bank_connection, result) }.not_to raise_error

      # the one good row lands; the id-less and date-less rows are skipped, not fatal
      expect(account.transaction_records.count).to eq(1)
      expect(account.transaction_records.first.transaction_id).to eq("eb-tx-002")
    end

    it "tolerates a payload with no transactions" do
      result = easybank_sync_response.merge("transactions" => [])

      account = described_class.call(bank_connection, result)

      expect(account.transaction_records.count).to eq(0)
      expect(account.balance_amount).to eq(BigDecimal("-980.31"))
    end
  end
end
