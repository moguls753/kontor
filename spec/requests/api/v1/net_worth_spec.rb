require "rails_helper"

RSpec.describe "Api::V1::NetWorth", type: :request do
  let(:user) { create(:user, password: "password123") }
  let(:bc) { create(:bank_connection, user: user) }
  before { post session_path, params: { email_address: user.email_address, password: "password123" }, as: :json }

  def snapshot(account, days_ago, amount)
    create(:balance_snapshot, account: account, snapshot_on: Date.current - days_ago, balance_amount: amount)
  end

  it "returns one per-account series with the documented shape" do
    acct = create(:account, bank_connection: bc, name: "Giro", role: "giro", role_locked: true, balance_amount: 100)
    snapshot(acct, 2, 80)
    snapshot(acct, 1, 90)
    snapshot(acct, 0, 100)

    get api_v1_net_worth_path, as: :json
    expect(response).to have_http_status(:ok)
    body = response.parsed_body

    expect(body).to include("range", "accounts", "summary")
    expect(body["range"]).to include("from" => (Date.current - 2).iso8601, "to" => Date.current.iso8601)
    expect(body["accounts"].size).to eq(1)

    a = body["accounts"].first
    expect(a).to include("id" => acct.id, "name" => "Giro", "role" => "giro", "investment" => false)
    expect(a["earliest"]).to eq((Date.current - 2).iso8601)
    expect(a["series"].last).to include("date" => Date.current.iso8601)
    expect(a["series"].last["balance"]).to be_a(String) # money serialised as a decimal string
    expect(a["series"].last["balance"].to_f).to eq(100.0)
  end

  # NW1 — the latest total must equal the dashboard's total balance for the same scope
  # (the trust anchor), compared as BigDecimal both sides.
  it "matches the dashboard total balance (NW1) under familie and privat" do
    privat = create(:account, bank_connection: bc, balance_amount: 300, shared: false)
    gemein = create(:account, bank_connection: bc, balance_amount: 200, shared: true)
    snapshot(privat, 0, 300)
    snapshot(gemein, 0, 200)

    get api_v1_net_worth_path, as: :json
    nw = response.parsed_body
    get api_v1_dashboard_path, as: :json
    dash = response.parsed_body
    expect(BigDecimal(nw["summary"]["latest"]["total"])).to eq(BigDecimal("500"))
    expect(nw["summary"]["latest"]["total"].to_f).to eq(dash["total_balance"].to_f)

    get api_v1_net_worth_path, params: { scope: "privat" }, as: :json
    expect(BigDecimal(response.parsed_body["summary"]["latest"]["total"])).to eq(BigDecimal("300"))
  end

  it "omits the shared account entirely under privat scope (membership, not netting)" do
    privat = create(:account, bank_connection: bc, balance_amount: 300, shared: false, name: "Privat")
    gemein = create(:account, bank_connection: bc, balance_amount: 200, shared: true, name: "Gemein")
    snapshot(privat, 0, 300)
    snapshot(gemein, 0, 200)

    get api_v1_net_worth_path, params: { scope: "privat" }, as: :json
    ids = response.parsed_body["accounts"].map { |a| a["id"] }
    expect(ids).to contain_exactly(privat.id)
  end

  it "preserves each account's own depth and clamps the combined start to the shallowest" do
    deep = create(:account, bank_connection: bc, name: "easybank")
    shallow = create(:account, bank_connection: bc, name: "giro")
    snapshot(deep, 100, 10)
    snapshot(deep, 0, 20)
    snapshot(shallow, 20, 5)
    snapshot(shallow, 0, 8)

    get api_v1_net_worth_path, as: :json
    body = response.parsed_body
    by_id = body["accounts"].index_by { |a| a["id"] }
    expect(by_id[deep.id]["earliest"]).to eq((Date.current - 100).iso8601)
    expect(by_id[shallow.id]["earliest"]).to eq((Date.current - 20).iso8601)
    # clamped_from = max(earliest) = where the all-accounts line can start
    expect(body["summary"]["clamped_from"]).to eq((Date.current - 20).iso8601)
    # range.from = min(earliest) = the deepest single-account history
    expect(body["range"]["from"]).to eq((Date.current - 100).iso8601)
  end

  it "carries the last known balance forward across a missed day" do
    acct = create(:account, bank_connection: bc, balance_amount: 50)
    snapshot(acct, 3, 30)
    # no snapshot on -2 / -1
    snapshot(acct, 0, 50)

    get api_v1_net_worth_path, as: :json
    by_date = response.parsed_body["accounts"].first["series"].index_by { |p| p["date"] }
    expect(by_date[(Date.current - 2).iso8601]["balance"].to_f).to eq(30.0)
    expect(by_date[(Date.current - 1).iso8601]["balance"].to_f).to eq(30.0)
    expect(by_date[Date.current.iso8601]["balance"].to_f).to eq(50.0)
  end

  it "windows the series to ?from= and seeds the first day via carry-forward" do
    acct = create(:account, bank_connection: bc, balance_amount: 50)
    snapshot(acct, 10, 10)
    snapshot(acct, 5, 30)
    snapshot(acct, 0, 50)

    get api_v1_net_worth_path, params: { from: (Date.current - 3).iso8601 }, as: :json
    series = response.parsed_body["accounts"].first["series"]
    expect(series.first["date"]).to eq((Date.current - 3).iso8601)
    expect(series.first["balance"].to_f).to eq(30.0) # latest snapshot ≤ (today-3) = the -5 row
    expect(series.last["date"]).to eq(Date.current.iso8601)
  end

  # Clamp AND window together: ?from inside both accounts' history must drive range.from,
  # clamped_from, and every series' first date to `from` — not to either account's own
  # (deeper) earliest snapshot. Guards against computing the clamp from unwindowed data.
  it "windows and clamps together for accounts of differing depth" do
    deep = create(:account, bank_connection: bc, name: "deep")
    shallow = create(:account, bank_connection: bc, name: "shallow")
    snapshot(deep, 100, 10); snapshot(deep, 0, 20)
    snapshot(shallow, 20, 5); snapshot(shallow, 0, 8)
    from = (Date.current - 10).iso8601

    get api_v1_net_worth_path, params: { from: from }, as: :json
    body = response.parsed_body
    expect(body["range"]["from"]).to eq(from)
    expect(body["summary"]["clamped_from"]).to eq(from)
    body["accounts"].each { |a| expect(a["series"].first["date"]).to eq(from) }
  end

  it "flags investment/sparkonto accounts and excludes them from the liquid summary" do
    # role_locked so the after_commit role-inferrer doesn't override the role under test.
    giro = create(:account, bank_connection: bc, role: "giro", role_locked: true, balance_amount: 100)
    depot = create(:account, bank_connection: bc, role: "investment", role_locked: true, balance_amount: 1000)
    spar = create(:account, bank_connection: bc, role: "sparkonto", role_locked: true, balance_amount: 500)
    [giro, depot, spar].each { |a| snapshot(a, 0, a.balance_amount) }

    get api_v1_net_worth_path, as: :json
    body = response.parsed_body
    by_id = body["accounts"].index_by { |a| a["id"] }
    expect(by_id[giro.id]["investment"]).to be(false)
    expect(by_id[depot.id]["investment"]).to be(true)
    expect(by_id[spar.id]["investment"]).to be(true)

    expect(BigDecimal(body["summary"]["latest"]["total"])).to eq(BigDecimal("1600"))
    expect(BigDecimal(body["summary"]["latest"]["liquid"])).to eq(BigDecimal("100")) # giro only
  end

  it "returns empty accounts and a zero summary for an empty scope (no 500)" do
    gemein = create(:account, bank_connection: bc, balance_amount: 200, shared: true)
    snapshot(gemein, 0, 200)

    get api_v1_net_worth_path, params: { scope: "privat" }, as: :json
    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body["accounts"]).to eq([])
    expect(body["summary"]["latest"]["total"].to_f).to eq(0.0)
    expect(body["summary"]["latest"]["liquid"].to_f).to eq(0.0)
    expect(body["summary"]["clamped_from"]).to be_nil
  end

  it "does not leak another user's accounts" do
    mine = create(:account, bank_connection: bc, name: "Mine", balance_amount: 100)
    snapshot(mine, 0, 100)
    other = create(:account, name: "Theirs", balance_amount: 999) # different user via factory's default bc
    create(:balance_snapshot, account: other, snapshot_on: Date.current, balance_amount: 999)

    get api_v1_net_worth_path, as: :json
    ids = response.parsed_body["accounts"].map { |a| a["id"] }
    expect(ids).to contain_exactly(mine.id)
  end
end
