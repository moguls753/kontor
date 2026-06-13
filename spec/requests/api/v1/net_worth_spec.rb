require "rails_helper"

RSpec.describe "Api::V1::NetWorth", type: :request do
  let(:user) { create(:user, password: "password123") }
  let(:bc) { create(:bank_connection, user: user) }
  before { post session_path, params: { email_address: user.email_address, password: "password123" }, as: :json }

  # role_locked so the after_commit role-inferrer doesn't override the role under test.
  def giro(balance:, shared: false, name: "Giro")
    create(:account, bank_connection: bc, role: "giro", role_locked: true, shared: shared, name: name, balance_amount: balance)
  end

  def tx(account, days_ago, amount)
    create(:transaction_record, account: account, amount: amount, booking_date: Date.current - days_ago, status: "booked")
  end

  it "returns Liquide + Gesamt aggregate lines reconstructed from transactions" do
    g = giro(balance: 100)
    tx(g, 5, 50)  # +50 five days ago
    tx(g, 2, -30) # −30 two days ago

    get api_v1_net_worth_path, as: :json
    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body).to include("range", "series", "latest", "composition")
    expect(body["series"].first).to include("date", "liquid", "total")
    # window starts at the earliest transaction (reconstruction depth)
    expect(body["range"]["from"]).to eq((Date.current - 5).iso8601)
    # opening (before the +50) = 100 − (50 − 30) = 80; today = current balance = 100
    expect(body["series"].first["total"].to_f).to eq(80.0)
    expect(body["series"].last["total"].to_f).to eq(100.0)
    # single account, no investment → Liquide == Gesamt
    expect(body["series"].last["liquid"].to_f).to eq(100.0)
  end

  it "ends the line at the live balance, not the start-of-day value, on a same-day-tx day" do
    g = giro(balance: 100)
    tx(g, 5, 20)
    tx(g, 0, -15) # booked TODAY — start-of-day would be 115, the live balance is 100

    get api_v1_net_worth_path, as: :json
    body = response.parsed_body
    # the chart's right edge must equal the "today" headline (current balance), not start-of-day
    expect(body["latest"]["total"].to_f).to eq(100.0)
    expect(body["series"].last["total"].to_f).to eq(body["latest"]["total"].to_f)
  end

  # NW1: latest == the dashboard's total balance for the scope; scope = account membership.
  it "matches the dashboard total (NW1) and is scope-aware" do
    privat = giro(balance: 300, shared: false)
    tx(privat, 3, 10)
    gemein = giro(balance: 200, shared: true, name: "Joint")
    tx(gemein, 3, 10)

    get api_v1_net_worth_path, as: :json
    nw = response.parsed_body
    expect(BigDecimal(nw["latest"]["total"])).to eq(BigDecimal("500"))
    get api_v1_dashboard_path, as: :json
    expect(nw["latest"]["total"].to_f).to eq(response.parsed_body["total_balance"].to_f)

    get api_v1_net_worth_path, params: { scope: "privat" }, as: :json
    privat_body = response.parsed_body
    expect(BigDecimal(privat_body["latest"]["total"])).to eq(BigDecimal("300"))
    expect(privat_body["composition"].map { |c| c["name"] }).not_to include("Joint")
  end

  it "splits Liquide (excludes investment) from Gesamt" do
    g = giro(balance: 100)
    tx(g, 4, 10)
    depot = create(:account, bank_connection: bc, role: "investment", role_locked: true, balance_amount: 1000)
    create(:balance_snapshot, account: depot, snapshot_on: Date.current, balance_amount: 1000)

    get api_v1_net_worth_path, as: :json
    last = response.parsed_body["series"].last
    expect(last["total"].to_f).to eq(1100.0) # giro + depot
    expect(last["liquid"].to_f).to eq(100.0)  # giro only — investment excluded
  end

  it "flat-fills a broker from snapshots and does NOT reconstruct it from transactions" do
    g = giro(balance: 100)
    tx(g, 10, 5)
    depot = create(:account, bank_connection: bc, role: "investment", role_locked: true, balance_amount: 1200)
    # an investment account is never reconstructed, even with a transaction present:
    create(:transaction_record, account: depot, amount: -999, booking_date: Date.current - 1, status: "booked")
    create(:balance_snapshot, account: depot, snapshot_on: Date.current - 2, balance_amount: 1200)

    get api_v1_net_worth_path, as: :json
    last = response.parsed_body["series"].last
    expect(last["total"].to_f - last["liquid"].to_f).to eq(1200.0) # flat 1200, the −999 ignored
  end

  it "clamps the window to the latest-starting reconstructable account" do
    deep = giro(balance: 50, name: "deep")
    tx(deep, 100, 5)
    shallow = giro(balance: 50, name: "shallow")
    tx(shallow, 20, 5)

    get api_v1_net_worth_path, as: :json
    expect(response.parsed_body["range"]["from"]).to eq((Date.current - 20).iso8601)
  end

  it "returns an empty payload for an empty scope (no 500)" do
    gemein = giro(balance: 200, shared: true)
    tx(gemein, 2, 5)

    get api_v1_net_worth_path, params: { scope: "privat" }, as: :json
    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body["series"]).to eq([])
    expect(body["latest"]["total"].to_f).to eq(0.0)
  end

  it "does not leak another user's accounts" do
    mine = giro(balance: 100, name: "Mine")
    tx(mine, 2, 5)
    other = create(:account, role: "giro", role_locked: true, balance_amount: 999) # different user (factory's own bc)
    create(:transaction_record, account: other, amount: 5, booking_date: Date.current - 2, status: "booked")

    get api_v1_net_worth_path, as: :json
    expect(BigDecimal(response.parsed_body["latest"]["total"])).to eq(BigDecimal("100"))
  end
end
