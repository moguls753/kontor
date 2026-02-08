require "rails_helper"

RSpec.describe "Api::V1::Dashboard", type: :request do
  let(:user) { create(:user, password: "password123") }
  before { post session_path, params: { email_address: user.email_address, password: "password123" }, as: :json }

  it "returns aggregated data" do
    bc = create(:bank_connection, user: user)
    account = create(:account, bank_connection: bc, balance_amount: 1000)
    create(:transaction_record, account: account, amount: -50, booking_date: Date.current)
    create(:transaction_record, :credit, account: account, booking_date: Date.current)

    get api_v1_dashboard_path, as: :json
    body = response.parsed_body
    expect(body["total_balance"]).to eq("1000.0")
    expect(body["transaction_count"]).to eq(2)
    expect(body["recent_transactions"].length).to eq(2)
    expect(body["recent_transactions"].first).to have_key("account_name")
  end

  it "returns zeros when empty" do
    get api_v1_dashboard_path, as: :json
    body = response.parsed_body
    expect(body["total_balance"]).to eq("0.0")
    expect(body["transaction_count"]).to eq(0)
    expect(body["accounts"]).to eq([])
    expect(body["uncategorized_count"]).to eq(0)
    expect(body["balance_change"]).to eq("0.0")
    expect(body["balance_change_percent"]).to be_nil
  end

  it "returns balance change and percent" do
    bc = create(:bank_connection, user: user)
    account = create(:account, bank_connection: bc, balance_amount: 1100)
    create(:transaction_record, :credit, account: account, amount: 100, booking_date: Date.current)

    get api_v1_dashboard_path, as: :json
    body = response.parsed_body
    expect(body["balance_change"]).to eq("100.0")
    expect(body["balance_change_percent"]).to eq(10.0)
  end

  it "returns accounts summary" do
    bc = create(:bank_connection, user: user)
    create(:account, bank_connection: bc, name: "Girokonto", iban: "DE89370400440532013000", balance_amount: 500)
    create(:account, bank_connection: bc, name: "Sparkonto", iban: "DE12345678901234567890", balance_amount: 1500)

    get api_v1_dashboard_path, as: :json
    body = response.parsed_body
    expect(body["accounts"].length).to eq(2)
    expect(body["accounts"].first).to include("name", "iban", "balance_amount", "currency")
  end

  it "returns uncategorized count" do
    bc = create(:bank_connection, user: user)
    account = create(:account, bank_connection: bc, balance_amount: 1000)
    category = create(:category, user: user)
    create(:transaction_record, account: account, booking_date: Date.current, category: category)
    create(:transaction_record, account: account, booking_date: Date.current, category: nil)

    get api_v1_dashboard_path, as: :json
    body = response.parsed_body
    expect(body["uncategorized_count"]).to eq(1)
  end
end
