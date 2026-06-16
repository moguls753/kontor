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

  it "excludes a matched internal transfer (both legs in scope) from income/expenses" do
    bc = create(:bank_connection, user: user)
    giro = create(:account, bank_connection: bc, balance_amount: 1000)
    spar = create(:account, bank_connection: bc, balance_amount: 500)
    group = SecureRandom.uuid

    # Eike's internal umbuchung: -70 out of giro, +70 into spar, matched together.
    create(:transaction_record, account: giro, amount: -70, booking_date: Date.current,
                                transfer_group_id: group, transfer_counterpart_account: spar)
    create(:transaction_record, account: spar, amount: 70, booking_date: Date.current,
                                transfer_group_id: group, transfer_counterpart_account: giro)

    get api_v1_dashboard_path, as: :json
    body = response.parsed_body
    expect(body["income"]).to eq("0.0")
    expect(body["expenses"]).to eq("0.0")
  end

  it "counts a cross-scope contribution per lens (income to the joint pot, expense from privat)" do
    bc = create(:bank_connection, user: user)
    privat = create(:account, bank_connection: bc, balance_amount: 1000, shared: false)
    gemein = create(:account, bank_connection: bc, balance_amount: 500, shared: true)
    group = SecureRandom.uuid

    # Eike's Ansparen: -70 out of the personal giro into the shared (Gemeinschafts-) account.
    create(:transaction_record, account: privat, amount: -70, booking_date: Date.current,
                                transfer_group_id: group, transfer_counterpart_account: gemein)
    create(:transaction_record, account: gemein, amount: 70, booking_date: Date.current,
                                transfer_group_id: group, transfer_counterpart_account: privat)

    # Gemeinsam (default): only the shared account is in scope → the +70 joint-side leg's
    # counterpart (the personal giro) is out of scope → it counts as a real inflow to the pot.
    get api_v1_dashboard_path, as: :json
    gem = response.parsed_body
    expect(gem["income"]).to eq("70.0")
    expect(gem["expenses"]).to eq("0.0")
    expect(gem["total_balance"]).to eq("500.0")

    # Privat: the shared account drops out of S → the -70 leg's counterpart is now
    # out of scope → it counts as a real outflow; the +70 leg vanishes with its account.
    get api_v1_dashboard_path, params: { scope: "privat" }, as: :json
    priv = response.parsed_body
    expect(priv["income"]).to eq("0.0")
    expect(priv["expenses"]).to eq("-70.0")
    expect(priv["total_balance"]).to eq("1000.0")
  end

  # A1 fallback: with NO shared account the default (gemeinsam) lens would be empty, so it
  # collapses to ALL accounts — a single-account install must still see its money.
  it "falls back to all accounts in the default lens when the user has no shared account" do
    bc = create(:bank_connection, user: user)
    a = create(:account, bank_connection: bc, balance_amount: 600)
    b = create(:account, bank_connection: bc, balance_amount: 400)
    create(:transaction_record, :credit, account: a, amount: 150, booking_date: Date.current)

    get api_v1_dashboard_path, as: :json
    body = response.parsed_body
    expect(body["total_balance"]).to eq("1000.0") # both accounts, not an empty shared scope
    expect(body["income"]).to eq("150.0")
    expect(body["accounts"].map { |x| x["id"] }).to contain_exactly(a.id, b.id)
  end

  it "counts an unmatched inflow as income with correct total_balance" do
    bc = create(:bank_connection, user: user)
    giro = create(:account, bank_connection: bc, balance_amount: 1000)
    # Katja's unmatched inflow — no transfer_group_id → real flow.
    create(:transaction_record, :credit, account: giro, amount: 200, booking_date: Date.current)

    get api_v1_dashboard_path, as: :json
    body = response.parsed_body
    expect(body["income"]).to eq("200.0")
    expect(body["total_balance"]).to eq("1000.0")
  end
end
