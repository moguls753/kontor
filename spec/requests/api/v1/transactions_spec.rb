require "rails_helper"

RSpec.describe "Api::V1::Transactions", type: :request do
  let(:user) { create(:user, password: "password123") }
  let(:bc) { create(:bank_connection, user: user) }
  let(:account) { create(:account, bank_connection: bc) }
  before { post session_path, params: { email_address: user.email_address, password: "password123" }, as: :json }

  it "returns paginated transactions" do
    create_list(:transaction_record, 3, account: account)
    get api_v1_transactions_path, as: :json

    body = response.parsed_body
    expect(body["transactions"].length).to eq(3)
    expect(body["meta"]["total"]).to eq(3)
  end

  it "filters out shared-account transactions in ?scope=privat" do
    personal_acct = create(:account, bank_connection: bc, shared: false)
    shared_acct   = create(:account, bank_connection: bc, shared: true)
    create(:transaction_record, account: personal_acct, remittance: "Privat tx")
    create(:transaction_record, account: shared_acct, remittance: "Gemeinschaft tx")

    get api_v1_transactions_path, params: { scope: "privat" }, as: :json
    remittances = response.parsed_body["transactions"].map { |t| t["remittance"] }
    expect(remittances).to include("Privat tx")
    expect(remittances).not_to include("Gemeinschaft tx")
  end

  it "shows a cross-scope transfer leg as a flow in privat but hides it in familie" do
    personal_acct = create(:account, bank_connection: bc, shared: false)
    shared_acct   = create(:account, bank_connection: bc, shared: true)
    group = SecureRandom.uuid
    create(:transaction_record, account: personal_acct, amount: -70, remittance: "Ansparen",
                                transfer_group_id: group, transfer_counterpart_account: shared_acct)
    create(:transaction_record, account: shared_acct, amount: 70, remittance: "Ansparen in",
                                transfer_group_id: group, transfer_counterpart_account: personal_acct)

    # Familie: both legs in scope → internal transfer → both excluded.
    get api_v1_transactions_path, params: { scope: "familie" }, as: :json
    expect(response.parsed_body["transactions"].map { |t| t["remittance"] }).not_to include("Ansparen", "Ansparen in")

    # Privat: shared account out of scope → the personal leg becomes a real flow.
    get api_v1_transactions_path, params: { scope: "privat" }, as: :json
    expect(response.parsed_body["transactions"].map { |t| t["remittance"] }).to eq(["Ansparen"])
  end

  # §4a fix — an orphaned transfer leg (transfer_group_id still set, but the counterpart
  # account was deleted ⇒ transfer_counterpart_account_id NULL) is a real flow, not a
  # net-zero internal transfer, and must stay visible. The exclusion keys on the
  # counterpart id, never on transfer_group_id (NULL NOT IN → NULL → would silently drop it).
  it "keeps an orphaned transfer leg (counterpart account deleted) visible as a real flow" do
    create(:transaction_record, account: account, amount: -90, remittance: "Orphaned leg",
                                transfer_group_id: SecureRandom.uuid, transfer_counterpart_account: nil)

    get api_v1_transactions_path, params: { scope: "familie" }, as: :json
    expect(response.parsed_body["transactions"].map { |t| t["remittance"] }).to include("Orphaned leg")
  end

  it "still excludes a genuinely-matched in-scope internal transfer (both legs visible)" do
    other_acct = create(:account, bank_connection: bc)
    group = SecureRandom.uuid
    create(:transaction_record, account: account, amount: -90, remittance: "Matched out",
                                transfer_group_id: group, transfer_counterpart_account: other_acct)
    create(:transaction_record, account: other_acct, amount: 90, remittance: "Matched in",
                                transfer_group_id: group, transfer_counterpart_account: account)

    get api_v1_transactions_path, params: { scope: "familie" }, as: :json
    remittances = response.parsed_body["transactions"].map { |t| t["remittance"] }
    expect(remittances).not_to include("Matched out", "Matched in")
  end

  it "filters by date range and account" do
    create(:transaction_record, account: account, booking_date: "2026-01-15")
    create(:transaction_record, account: account, booking_date: "2025-12-01")

    get api_v1_transactions_path, params: { from: "2026-01-01", to: "2026-01-31", account_id: account.id }, as: :json
    expect(response.parsed_body["transactions"].length).to eq(1)
  end

  it "filters uncategorized" do
    create(:transaction_record, account: account, category: create(:category, user: user))
    create(:transaction_record, account: account, category: nil)

    get api_v1_transactions_path, params: { uncategorized: "true" }, as: :json
    expect(response.parsed_body["transactions"].length).to eq(1)
  end

  it "searches by remittance text" do
    create(:transaction_record, account: account, remittance: "REWE Markt")
    create(:transaction_record, account: account, remittance: "Gehalt", creditor_name: "Arbeitgeber")

    get api_v1_transactions_path, params: { search: "REWE" }, as: :json
    expect(response.parsed_body["transactions"].length).to eq(1)
  end

  describe "POST /categorize" do
    it "runs categorization and returns results" do
      create(:llm_credential, user: user)
      categorizer = instance_double(LlmCategorizer)
      allow(LlmCategorizer).to receive(:new).with(user).and_return(categorizer)
      allow(categorizer).to receive(:categorize_uncategorized).and_return({ total: 5, categorized: 3, failed: 0 })

      post categorize_api_v1_transactions_path, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["categorized"]).to eq(3)
    end

    it "returns 422 when LLM is not configured" do
      post categorize_api_v1_transactions_path, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
