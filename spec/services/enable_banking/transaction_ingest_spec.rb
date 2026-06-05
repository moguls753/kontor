require "rails_helper"

RSpec.describe EnableBanking::TransactionIngest do
  let(:user) { create(:user) }
  let(:bc) { create(:bank_connection, user: user, provider: "enable_banking") }
  let(:account) { create(:account, bank_connection: bc) }

  describe ".call" do
    it "prefers transaction_id, signs debits, and is idempotent" do
      described_class.call(account, eb_transactions_response[:transactions])
      described_class.call(account, eb_transactions_response[:transactions])

      expect(account.transaction_records.count).to eq(2)
      expect(account.transaction_records.find_by(transaction_id: "tx-001").amount).to eq(-42.50)
      expect(account.transaction_records.find_by(transaction_id: "tx-002").amount).to eq(2500.00)
    end

    it "keys on entry_reference when transaction_id is absent, idempotently (no surrogate)" do
      described_class.call(account, eb_transactions_response_entry_reference_only[:transactions])
      described_class.call(account, eb_transactions_response_entry_reference_only[:transactions])

      expect(account.transaction_records.count).to eq(1)
      row = account.transaction_records.first
      expect(row.transaction_id).to eq("entryref-9001")
      expect(row.transaction_id).not_to start_with("eb-gen-")
      expect(row.amount).to eq(-73.40)
    end

    it "ingests id-less rows via fundamental matching with surrogate ids, idempotently" do
      described_class.call(account, eb_transactions_response_without_ids[:transactions])
      described_class.call(account, eb_transactions_response_without_ids[:transactions])

      expect(account.transaction_records.count).to eq(2)
      expect(account.transaction_records.pluck(:transaction_id)).to all(start_with("eb-gen-"))
    end

    it "updates an id-less row in place when its mutable fields drift" do
      described_class.call(account, eb_transactions_response_without_ids[:transactions])
      original_id = account.transaction_records.find_by(amount: -31.00).transaction_id

      described_class.call(account, eb_transactions_response_without_ids_mutated[:transactions])

      row = account.transaction_records.find_by(amount: -31.00)
      expect(account.transaction_records.count).to eq(2)
      expect(row.transaction_id).to eq(original_id)
      expect(row.remittance).to eq("PayPal settled")
    end

    it "treats two same-day same-amount id-less rows as two distinct rows" do
      described_class.call(account, eb_transactions_response_same_day_pair[:transactions])

      expect(account.transaction_records.count).to eq(2)
      expect(account.transaction_records.pluck(:remittance)).to contain_exactly("Spotify", "Netflix")
    end

    it "keeps two fully identical id-less rows as two rows, idempotently across re-syncs" do
      described_class.call(account, eb_transactions_response_identical_pair[:transactions])
      described_class.call(account, eb_transactions_response_identical_pair[:transactions])

      expect(account.transaction_records.count).to eq(2)
      expect(account.transaction_records.pluck(:transaction_id)).to all(start_with("eb-gen-"))
      expect(account.transaction_records.pluck(:remittance)).to eq([ "Cafe Central", "Cafe Central" ])
    end

    it "upgrades an id-less surrogate row in place when it later gains an entry_reference (no dupe)" do
      described_class.call(account, eb_transactions_response_forward_flip_before[:transactions])
      surrogate_id = account.transaction_records.sole.transaction_id
      expect(surrogate_id).to start_with("eb-gen-")

      described_class.call(account, eb_transactions_response_forward_flip_after[:transactions])

      row = account.transaction_records.sole
      expect(row.transaction_id).to eq("flip-ref-7001")
      expect(row.entry_reference).to eq("flip-ref-7001")
    end

    it "keeps two booked txs that share one entry_reference as two rows, idempotently" do
      described_class.call(account, eb_transactions_response_shared_entry_reference[:transactions])

      expect(account.transaction_records.count).to eq(2)
      expect(account.transaction_records.pluck(:amount)).to contain_exactly(-10.00, -20.00)

      described_class.call(account, eb_transactions_response_shared_entry_reference[:transactions])
      expect(account.transaction_records.count).to eq(2)
      expect(account.transaction_records.pluck(:amount)).to contain_exactly(-10.00, -20.00)
    end

    it "does not overwrite an earlier row when a LATER tx reuses its per-statement entry_reference cross-sync" do
      described_class.call(account, eb_transactions_response_shared_entry_reference_earlier[:transactions])
      described_class.call(account, eb_transactions_response_shared_entry_reference_later[:transactions])

      expect(account.transaction_records.count).to eq(2)
      expect(account.transaction_records.pluck(:amount)).to contain_exactly(-99.00, -12.00)
      # The earlier entry_reference-keyed row is preserved untouched.
      earlier = account.transaction_records.find_by(amount: -99.00)
      expect(earlier.transaction_id).to eq("stmt-0001")
      expect(earlier.remittance).to eq("Rent B")
      # The later same-reference tx became its own surrogate row.
      later = account.transaction_records.find_by(amount: -12.00)
      expect(later.transaction_id).to start_with("eb-gen-")
      expect(later.remittance).to eq("Coffee A")
    end

    it "skips a rejected (non-booked) row, storing only the booked one" do
      described_class.call(account, eb_transactions_response_with_rejected[:transactions])

      expect(account.transaction_records.pluck(:transaction_id)).to eq([ "tx-booked-ok" ])
      expect(account.transaction_records.find_by(transaction_id: "tx-rejected")).to be_nil
      expect(account.transaction_records.first.status).to eq("booked")
    end

    it "skips pending rows and normalizes the stored status to booked" do
      described_class.call(account, eb_transactions_response_with_pending[:transactions])

      expect(account.transaction_records.pluck(:transaction_id)).to eq([ "tx-booked-1" ])
      expect(account.transaction_records.first.status).to eq("booked")
    end

    it "skips a malformed row without aborting the batch" do
      malformed = { transaction_id: "bad", transaction_amount: { amount: "oops" } }
      good = eb_transactions_response[:transactions].first

      described_class.call(account, [ malformed, good ])

      expect(account.transaction_records.pluck(:transaction_id)).to eq([ "tx-001" ])
    end
  end
end
