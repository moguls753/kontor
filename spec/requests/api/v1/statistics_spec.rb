require "rails_helper"

RSpec.describe "Api::V1::Statistics", type: :request do
  let(:user) { create(:user, password: "password123") }
  let(:bc) { create(:bank_connection, user: user) }
  before { post session_path, params: { email_address: user.email_address, password: "password123" }, as: :json }

  # Statistics period that matches the dashboard's (this month) for parity checks.
  def this_month_params
    { from: Date.current.beginning_of_month.iso8601, to: Date.current.iso8601 }
  end

  it "returns the full set of sections" do
    account = create(:account, bank_connection: bc, balance_amount: 1000)
    create(:transaction_record, account: account, amount: -30, booking_date: Date.current)
    create(:transaction_record, :credit, account: account, amount: 200, booking_date: Date.current)

    get api_v1_statistics_path, params: this_month_params, as: :json
    expect(response).to have_http_status(:ok)
    body = response.parsed_body

    expect(body).to include("range", "kpis", "cashflow", "fixed_variable", "categories", "transaction_count")
    expect(body["kpis"]).to include("income", "expenses", "net", "savings_rate",
                                    "avg_monthly_expenses", "fixed_monthly", "recurring_payment_count")
    expect(body["categories"]).to include("spending", "transfers", "total_spent")
    expect(body["cashflow"].last).to include("month", "income", "expenses", "net")
  end

  # Invariant I1 — the page's headline numbers must equal the dashboard's for the
  # same period+scope (the trust anchor). Compared numerically (BigDecimal → "x.0").
  it "matches the dashboard's income/expenses for the same period" do
    account = create(:account, bank_connection: bc, balance_amount: 1000)
    create(:transaction_record, account: account, amount: -123.45, booking_date: Date.current)
    create(:transaction_record, :credit, account: account, amount: 678.90, booking_date: Date.current)

    get api_v1_dashboard_path, as: :json
    dash = response.parsed_body
    get api_v1_statistics_path, params: this_month_params, as: :json
    stat = response.parsed_body

    expect(stat["kpis"]["income"].to_f).to eq(dash["income"].to_f)
    expect(stat["kpis"]["expenses"].to_f).to eq(dash["expenses"].to_f)
  end

  # Under Privat, a recurring COST-share paid into the joint account (rent/utilities)
  # is a real outflow AND a fixed cost → must count as fixed. A recurring SAVINGS
  # transfer (Sparen category) is a real outflow but NOT a fixed cost.
  it "counts a recurring cost-share transfer as fixed under privat, but not a savings transfer" do
    privat = create(:account, bank_connection: bc, balance_amount: 1000, shared: false)
    gemein = create(:account, bank_connection: bc, balance_amount: 500, shared: true)
    miete = create(:recurring_series, user: user, canonical_name: "Eike Miete")
    sparen = create(:recurring_series, user: user, canonical_name: "Eike Sparen")
    wohnen_cat = create(:category, user: user, name: "Wohnen & Miete")
    sparen_cat = create(:category, user: user, name: "Sparen")
    g1 = SecureRandom.uuid
    g2 = SecureRandom.uuid

    # recurring rent-share privat → joint (real fixed cost)
    create(:transaction_record, account: privat, amount: -445, booking_date: Date.current, category: wohnen_cat,
                                recurring_series_id: miete.id, transfer_group_id: g1, transfer_counterpart_account: gemein)
    create(:transaction_record, account: gemein, amount: 445, booking_date: Date.current,
                                transfer_group_id: g1, transfer_counterpart_account: privat)
    # recurring savings transfer privat → joint (not a fixed cost)
    create(:transaction_record, account: privat, amount: -200, booking_date: Date.current, category: sparen_cat,
                                recurring_series_id: sparen.id, transfer_group_id: g2, transfer_counterpart_account: gemein)
    create(:transaction_record, account: gemein, amount: 200, booking_date: Date.current,
                                transfer_group_id: g2, transfer_counterpart_account: privat)

    get api_v1_statistics_path, params: this_month_params.merge(scope: "privat"), as: :json
    k = response.parsed_body["kpis"]

    expect(k["expenses"].to_f).to eq(-645.0)          # both legs are real privat outflows
    expect(k["fixed_monthly"].to_f).to eq(-445.0)     # only the cost-share is "fixed"
    expect(k["recurring_payment_count"]).to eq(1)     # savings series excluded from the count

    fv = response.parsed_body["fixed_variable"].last
    expect(fv["fixed"].to_f).to eq(-445.0)
    expect(fv["variable"].to_f).to eq(-200.0)
  end

  # Review S3 — Sparen/Überweisungen are split into a `transfers` group, and the two
  # groups always reconcile to total expenses (no hidden gap).
  it "splits transfer categories out yet reconciles to total expenses" do
    account = create(:account, bank_connection: bc, balance_amount: 1000)
    groceries = create(:category, user: user, name: "Lebensmittel & Getränke")
    sparen = create(:category, user: user, name: "Sparen")
    ueber = create(:category, user: user, name: "Überweisungen")
    create(:transaction_record, account: account, amount: -30, booking_date: Date.current, category: groceries)
    create(:transaction_record, account: account, amount: -100, booking_date: Date.current, category: sparen)
    create(:transaction_record, account: account, amount: -50, booking_date: Date.current, category: ueber)

    get api_v1_statistics_path, params: this_month_params, as: :json
    body = response.parsed_body
    cats = body["categories"]

    expect(cats["spending"].map { |i| i["name"] }).to eq(["Lebensmittel & Getränke"])
    expect(cats["transfers"].map { |i| i["name"] }).to match_array(["Sparen", "Überweisungen"])
    expect(cats["total_spent"].to_f).to eq(-30.0)

    reconciled = cats["spending"].sum { |i| i["amount"].to_f } + cats["transfers"].sum { |i| i["amount"].to_f }
    expect(reconciled).to be_within(0.001).of(body["kpis"]["expenses"].to_f)
  end

  it "buckets cashflow by month across a year boundary" do
    account = create(:account, bank_connection: bc, balance_amount: 1000)
    create(:transaction_record, account: account, amount: -10, booking_date: Date.new(2025, 12, 15))
    create(:transaction_record, :credit, account: account, amount: 100, booking_date: Date.new(2026, 1, 10))

    get api_v1_statistics_path, params: { from: "2025-12-01", to: "2026-01-31" }, as: :json
    cashflow = response.parsed_body["cashflow"]

    expect(cashflow.map { |c| c["month"] }).to eq(["2025-12", "2026-01"])
    expect(cashflow.find { |c| c["month"] == "2025-12" }["expenses"].to_f).to eq(-10.0)
    expect(cashflow.find { |c| c["month"] == "2026-01" }["income"].to_f).to eq(100.0)
  end

  # Invariant I4 — a window starting before the first transaction is clamped to it.
  it "clamps the window start to the earliest transaction" do
    account = create(:account, bank_connection: bc, balance_amount: 1000)
    create(:transaction_record, account: account, amount: -10, booking_date: Date.current)

    get api_v1_statistics_path, params: { from: (Date.current - 1.year).iso8601, to: Date.current.iso8601 }, as: :json
    range = response.parsed_body["range"]

    expect(range["clamped"]).to be(true)
    expect(Date.iso8601(range["from"])).to eq(Date.current)
  end

  # Invariant I3 — no accounts in scope returns zeros, never a 500.
  it "returns zeros for an empty scope" do
    get api_v1_statistics_path, as: :json
    expect(response).to have_http_status(:ok)
    body = response.parsed_body

    expect(body["transaction_count"]).to eq(0)
    expect(body["categories"]["spending"]).to eq([])
    expect(body["kpis"]["income"].to_f).to eq(0.0)
    expect(body["kpis"]["savings_rate"]).to be_nil
  end

  it "requires authentication" do
    delete session_path, as: :json
    get api_v1_statistics_path, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it "never exposes another user's transactions" do
    other = create(:user, password: "password123")
    other_acc = create(:account, bank_connection: create(:bank_connection, user: other), balance_amount: 999)
    create(:transaction_record, account: other_acc, amount: -500, booking_date: Date.current)

    mine = create(:account, bank_connection: bc, balance_amount: 100)
    create(:transaction_record, account: mine, amount: -10, booking_date: Date.current)

    get api_v1_statistics_path, params: this_month_params, as: :json
    body = response.parsed_body
    expect(body["transaction_count"]).to eq(1)
    expect(body["kpis"]["expenses"].to_f).to eq(-10.0)
  end

  # Review SF1 — an absurdly old `from` must not build a multi-thousand-month series.
  it "bounds the month series for an out-of-range from param" do
    create(:account, bank_connection: bc, balance_amount: 100)
    get api_v1_statistics_path, params: { from: "0001-01-01", to: Date.current.iso8601 }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["cashflow"].length).to be <= 37
  end

  it "handles a from after to without error" do
    create(:account, bank_connection: bc, balance_amount: 100)
    get api_v1_statistics_path, params: { from: Date.current.iso8601, to: (Date.current - 2.months).iso8601 }, as: :json
    expect(response).to have_http_status(:ok)
  end

  # Avoid a meaningless +1000 % delta when the previous window has no data yet.
  it "suppresses the prior-period delta when the previous window predates the data" do
    account = create(:account, bank_connection: bc, balance_amount: 1000)
    create(:transaction_record, account: account, amount: -50, booking_date: Date.current)

    get api_v1_statistics_path, params: this_month_params, as: :json
    expect(response.parsed_body["kpis"]["avg_monthly_expenses_prev"]).to be_nil
  end
end
