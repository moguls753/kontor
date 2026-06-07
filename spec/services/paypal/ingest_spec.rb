require "rails_helper"

RSpec.describe Paypal::Ingest do
  let(:user) { create(:user) }
  let(:bank_connection) { create(:bank_connection, :paypal, user: user) }

  describe ".call" do
    it "creates the single PayPal account when none exists yet" do
      expect {
        described_class.call(bank_connection, paypal_sync_response)
      }.to change { bank_connection.accounts.count }.from(0).to(1)

      account = bank_connection.accounts.find_by(account_uid: "paypal")
      expect(account.name).to eq("PayPal")
    end

    it "upserts booked transactions with signed amounts and the merchant/remittance mapping" do
      described_class.call(bank_connection, paypal_sync_response)

      account = bank_connection.accounts.find_by(account_uid: "paypal")
      debit = account.transaction_records.find_by(transaction_id: "55X63072JY995300U")
      credit = account.transaction_records.find_by(transaction_id: "3AB12345CD678901E")

      expect(debit.amount).to eq(BigDecimal("-8.15"))
      expect(debit.currency).to eq("EUR")
      expect(debit.status).to eq("booked")
      expect(debit.remittance).to eq("Zahlung")
      expect(debit.creditor_name).to eq("eBay S.a.r.l.")
      expect(debit.booking_date).to eq(Date.new(2026, 6, 6))

      expect(credit.amount).to eq(BigDecimal("79.00"))
      expect(credit.status).to eq("booked")
    end

    it "stores a synthetic-id (pp-syn-) row like any other" do
      described_class.call(bank_connection, paypal_sync_response)

      account = bank_connection.accounts.find_by(account_uid: "paypal")
      syn = account.transaction_records.find_by(transaction_id: "pp-syn-0123456789abcdef0123")
      expect(syn).to be_present
      expect(syn.amount).to eq(BigDecimal("-10.60"))
      expect(syn.currency).to eq("USD")
    end

    it "deduplicates on transaction_id across repeat syncs (count stable)" do
      2.times { described_class.call(bank_connection, paypal_sync_response) }

      account = bank_connection.accounts.find_by(account_uid: "paypal")
      expect(account.transaction_records.count).to eq(3)
    end

    it "skips pending rows (booked-only)" do
      pending = paypal_sync_response["transactions"].first.merge("id" => "pp-pending", "is_pending" => true)
      result = paypal_sync_response.merge("transactions" => [pending])

      account = described_class.call(bank_connection, result)

      expect(account.transaction_records.find_by(transaction_id: "pp-pending")).to be_nil
      expect(account.transaction_records.count).to eq(0)
    end

    it "skips malformed rows (missing id or date) without aborting the batch" do
      good = paypal_sync_response["transactions"][1] # 3AB12345CD678901E
      result = paypal_sync_response.merge("transactions" => [
        { "id" => nil, "booking_date" => "2026-05-01", "amount" => "-1.00", "currency" => "EUR" },
        good,
        { "id" => "pp-no-date", "booking_date" => nil, "amount" => "-2.00", "currency" => "EUR" }
      ])

      account = nil
      expect { account = described_class.call(bank_connection, result) }.not_to raise_error

      expect(account.transaction_records.count).to eq(1)
      expect(account.transaction_records.first.transaction_id).to eq("3AB12345CD678901E")
    end

    it "sets the account's available balance from the PayPal-Guthaben card" do
      freeze_time do
        account = described_class.call(bank_connection, paypal_sync_response)

        expect(account.balance_amount).to eq(BigDecimal("0.00"))
        expect(account.currency).to eq("EUR")
        expect(account.balance_type).to eq("available")
        expect(account.balance_updated_at).to eq(Time.current)
      end
    end

    it "leaves the stored balance untouched when the sidecar balance is nil" do
      account = described_class.call(bank_connection, paypal_sync_response(balance: { "amount" => "12.34", "currency" => "EUR" }))
      expect(account.balance_amount).to eq(BigDecimal("12.34"))

      # A later sync that couldn't read the card must NOT zero/blank the balance.
      described_class.call(bank_connection, paypal_sync_response(balance: nil))
      expect(account.reload.balance_amount).to eq(BigDecimal("12.34"))
      expect(account.balance_type).to eq("available")
    end

    it "stamps last_synced_at on the account" do
      account = described_class.call(bank_connection, paypal_sync_response)
      expect(account.last_synced_at).to be_present
    end

    it "tolerates a payload with no transactions" do
      result = paypal_sync_response.merge("transactions" => [])
      account = described_class.call(bank_connection, result)
      expect(account.transaction_records.count).to eq(0)
    end
  end
end
