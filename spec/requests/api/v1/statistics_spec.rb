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

    expect(body).to include("range", "kpis", "cashflow", "fixed_variable", "categories", "transaction_count", "forecast")
    expect(body["kpis"]).to include("income", "expenses", "net", "savings_rate",
                                    "avg_monthly_expenses", "fixed_monthly", "recurring_payment_count")
    expect(body["categories"]).to include("items", "total")
    expect(body["forecast"]).to include("recurring_income", "recurring_expenses", "variable_income", "variable_expenses",
                                        "avg_window_months", "current_balance", "total_net", "liquid_balance", "liquid_net",
                                        "upcoming", "upcoming_total")
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

  # D-A4 — one ranked list: Sparen/Überweisungen are plain categories (no muted
  # group). The list is sorted by magnitude desc and reconciles to total expenses.
  it "returns one ranked category list (incl. Sparen/Überweisungen) that reconciles to expenses" do
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

    # all three categories appear in one list, largest magnitude first.
    expect(cats["items"].map { |i| i["name"] }).to eq(["Sparen", "Überweisungen", "Lebensmittel & Getränke"])
    expect(cats["total"].to_f).to eq(-180.0)

    reconciled = cats["items"].sum { |i| i["amount"].to_f }
    expect(reconciled).to be_within(0.001).of(body["kpis"]["expenses"].to_f)
    expect(reconciled).to be_within(0.001).of(cats["total"].to_f)
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
    expect(body["categories"]["items"]).to eq([])
    expect(body["kpis"]["income"].to_f).to eq(0.0)
    expect(body["kpis"]["savings_rate"]).to be_nil

    # Forecast zeros (serialized as decimal strings, not Integer 0) + empty upcoming.
    fc = body["forecast"]
    expect(fc["recurring_income"]).to eq("0.0")
    expect(fc["recurring_expenses"]).to eq("0.0")
    expect(fc["variable_income"]).to eq("0.0")
    expect(fc["variable_expenses"]).to eq("0.0")
    expect(fc["avg_window_months"]).to eq(0)
    expect(fc["current_balance"]).to eq("0.0")
    expect(fc["upcoming"]).to eq([])
    expect(fc["upcoming_total"]).to eq("0.0")
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

  describe "forecast (Vorschau nächste Monate)" do
    # recurring_income/recurring_expenses are the cadence-normalised run-rate of active
    # recurring contracts (both directions): |expected_amount| × 30 / cadence_days.
    it "normalises recurring income and expense series to a 30-day run-rate" do
      account = create(:account, bank_connection: bc, balance_amount: 5000)
      # biweekly outflow -70 → 70 × 30/14 = 150.00 (no transfer category).
      sub = create(:recurring_series, user: user, direction: "outflow", canonical_name: "Gym",
                                      cadence: "biweekly", cadence_days: 14, expected_amount: -70)
      create(:transaction_record, account: account, amount: -70, booking_date: Date.current - 14, recurring_series: sub)
      # monthly inflow 2500 → 2500 × 30/30 = 2500.00 income.
      salary = create(:recurring_series, :inflow, user: user, canonical_name: "Gehalt", expected_amount: 2500)
      create(:transaction_record, :credit, account: account, amount: 2500, booking_date: Date.current - 5, recurring_series: salary)

      get api_v1_statistics_path, params: this_month_params, as: :json
      fc = response.parsed_body["forecast"]

      expect(fc["recurring_income"].to_f).to eq(2500.0)
      expect(fc["recurring_expenses"].to_f).to eq(-150.0)   # signed negative
    end

    # The forecast skips series whose cadence yields no usable interval (irregular /
    # cadence_days ≤ 0) and any non-EUR series — no guess-30.
    it "skips irregular, zero-cadence and non-EUR series from the run-rate" do
      account = create(:account, bank_connection: bc, balance_amount: 5000)
      irregular = create(:recurring_series, user: user, direction: "outflow", canonical_name: "Irregular",
                                            cadence: "irregular", cadence_days: nil, expected_amount: -99)
      create(:transaction_record, account: account, amount: -99, booking_date: Date.current - 3, recurring_series: irregular)
      foreign = create(:recurring_series, user: user, direction: "outflow", canonical_name: "USD Sub",
                                          currency: "USD", expected_amount: -50)
      create(:transaction_record, account: account, amount: -50, booking_date: Date.current - 3, recurring_series: foreign)

      get api_v1_statistics_path, params: this_month_params, as: :json
      fc = response.parsed_body["forecast"]

      expect(fc["recurring_expenses"].to_f).to eq(0.0)
    end

    # The forecast is CASHFLOW, not the Fixkosten KPI: a recurring SAVINGS outflow is real
    # money leaving, so it counts in recurring_expenses (run-rate) — NOT excluded the way the
    # Fixkosten KPI excludes it. Being recurring-linked it does NOT also feed the variable
    # average (clean partition, no double-count).
    it "counts a recurring savings outflow in recurring_expenses, not in the variable average" do
      account = create(:account, bank_connection: bc, balance_amount: 5000)
      sparen_cat = create(:category, user: user, name: "Sparen")
      sparen = create(:recurring_series, user: user, direction: "outflow", canonical_name: "Ansparen",
                                         category: sparen_cat, expected_amount: -300)
      last_full = Date.current.beginning_of_month - 10.days
      3.times do |i|
        create(:transaction_record, account: account, amount: -300, category: sparen_cat,
                                    recurring_series: sparen, booking_date: last_full - (i * 30))
      end

      get api_v1_statistics_path, params: this_month_params, as: :json
      fc = response.parsed_body["forecast"]

      expect(fc["recurring_expenses"].to_f).to eq(-300.0)   # recurring outflow → cashflow, counted
      expect(fc["variable_expenses"].to_f).to eq(0.0)        # recurring-linked → not double-counted
    end

    # variable_expenses = avg of NON-recurring in-scope debits over the months-with-data in
    # the window (current partial month excluded; a recurring-linked debit does not count —
    # it's the run-rate). Here 3 months have data → ÷3.
    it "averages non-recurring debits over the months-with-data, excluding the current month" do
      account = create(:account, bank_connection: bc, balance_amount: 5000)
      fixed = create(:recurring_series, user: user, direction: "outflow", canonical_name: "Rent")
      # one -300 discretionary debit in each of the last 3 full months → (-900)/3 = -300.
      3.times do |i|
        create(:transaction_record, account: account, amount: -300,
                                    booking_date: Date.current.beginning_of_month - (i * 30 + 5).days)
      end
      # a recurring (run-rate) debit in a full month must NOT count toward variable.
      create(:transaction_record, account: account, amount: -1000, recurring_series: fixed,
                                  booking_date: Date.current.beginning_of_month - 5.days)
      # a debit in the CURRENT (partial) month must NOT count.
      create(:transaction_record, account: account, amount: -500, booking_date: Date.current)

      get api_v1_statistics_path, params: this_month_params, as: :json
      fc = response.parsed_body["forecast"]

      expect(fc["variable_expenses"].to_f).to eq(-300.0)
    end

    # Short-history edge (the user's hard requirement 2026-06-10): the divisor is
    # months-WITH-DATA, never the flat window. A brand-new account whose only full month of
    # variable spend is €600 must report €600/mo (÷1), not €100/mo (÷6) — dividing by the
    # window would dilute the rate toward zero exactly when data is thinnest.
    it "divides by months-with-data, never the flat window, when history is short" do
      account = create(:account, bank_connection: bc, balance_amount: 5000)
      # all variable spend lands in the single most-recent FULL calendar month.
      last_full = Date.current.beginning_of_month - 1.day
      create(:transaction_record, account: account, amount: -400, booking_date: last_full)
      create(:transaction_record, account: account, amount: -200, booking_date: last_full - 3.days)

      get api_v1_statistics_path, params: this_month_params, as: :json
      fc = response.parsed_body["forecast"]

      expect(fc["variable_expenses"].to_f).to eq(-600.0) # ÷1 (one month with data), not ÷6
    end

    # A FULL month with only recurring costs (zero discretionary spend) must still count
    # toward the divisor — it's a real €0-variable month that pulls the average DOWN.
    # Divisor = months of HISTORY (any in-scope tx), not months-that-had-variable-spend.
    it "counts a recurring-only month as a zero-variable month in the divisor" do
      account = create(:account, bank_connection: bc, balance_amount: 5000)
      fixed = create(:recurring_series, user: user, direction: "outflow", canonical_name: "Rent")
      bom = Date.current.beginning_of_month
      create(:transaction_record, account: account, amount: -300, booking_date: bom.prev_month(3) + 9.days) # month -3, variable
      create(:transaction_record, account: account, amount: -300, booking_date: bom.prev_month(1) + 9.days) # month -1, variable
      # month -2: ONLY a recurring debit — still a month of history → in the divisor.
      create(:transaction_record, account: account, amount: -1000, recurring_series: fixed,
                                  booking_date: bom.prev_month(2) + 9.days)

      get api_v1_statistics_path, params: this_month_params, as: :json
      # -600 variable over 3 months of history (incl. the recurring-only month) → -200, not -300 (÷2).
      expect(response.parsed_body["forecast"]["variable_expenses"].to_f).to eq(-200.0)
    end

    # Scope-awareness: a recurring rent-share (personal→joint) is a recurring expense under
    # Privat (counterpart out of scope) but netted away under Familie (both legs in scope) —
    # symmetric with the dashboard/statistics treatment.
    it "counts a cross-scope rent-share in recurring_expenses under privat but nets it under familie" do
      privat = create(:account, bank_connection: bc, balance_amount: 1000, shared: false)
      gemein = create(:account, bank_connection: bc, balance_amount: 500, shared: true)
      wohnen = create(:category, user: user, name: "Wohnen & Miete")
      rent = create(:recurring_series, user: user, direction: "outflow", canonical_name: "Mietanteil",
                                       category: wohnen, expected_amount: -445)
      g = SecureRandom.uuid
      create(:transaction_record, account: privat, amount: -445, category: wohnen, recurring_series: rent,
                                  booking_date: Date.current - 3, transfer_group_id: g, transfer_counterpart_account: gemein)
      create(:transaction_record, account: gemein, amount: 445, booking_date: Date.current - 3,
                                  transfer_group_id: g, transfer_counterpart_account: privat)

      get api_v1_statistics_path, params: this_month_params.merge(scope: "privat"), as: :json
      expect(response.parsed_body["forecast"]["recurring_expenses"].to_f).to eq(-445.0)

      get api_v1_statistics_path, params: this_month_params.merge(scope: "familie"), as: :json
      expect(response.parsed_body["forecast"]["recurring_expenses"].to_f).to eq(0.0) # netted → transfer bucket
    end

    # Under Privat, the inflow leg of an own-account transfer is a `transfer` bucket
    # (net-zero), so it must NOT inflate recurring_income.
    it "excludes an own-account inflow transfer leg from recurring_income under privat" do
      privat = create(:account, bank_connection: bc, balance_amount: 1000, shared: false)
      other  = create(:account, bank_connection: bc, balance_amount: 500, shared: false)
      series = create(:recurring_series, :inflow, user: user, canonical_name: "Umbuchung rein", expected_amount: 300)
      g = SecureRandom.uuid
      create(:transaction_record, :credit, account: privat, amount: 300, recurring_series: series,
                                  booking_date: Date.current - 3, transfer_group_id: g, transfer_counterpart_account: other)
      create(:transaction_record, account: other, amount: -300, booking_date: Date.current - 3,
                                  transfer_group_id: g, transfer_counterpart_account: privat)

      get api_v1_statistics_path, params: this_month_params.merge(scope: "privat"), as: :json
      # both legs in scope → net-zero transfer → income unaffected.
      expect(response.parsed_body["forecast"]["recurring_income"].to_f).to eq(0.0)
    end

    # Symmetric variable average (redesign 2026-06-10): non-recurring CREDITS (refunds,
    # one-off income) are averaged into variable_income just as non-recurring DEBITS feed
    # variable_expenses — so a one-off and its refund offset. ⚠️ Divisor = months-WITH-DATA
    # (here 2), never the flat window.
    it "averages variable income and expenses symmetrically over months-with-data only" do
      account = create(:account, bank_connection: bc, balance_amount: 5000)
      bom = Date.current.beginning_of_month
      # Only two full months have data (−1 and −2); months −3..−6 of the window are empty.
      create(:transaction_record, account: account, amount: -600, booking_date: bom.prev_month(1) + 9.days)
      create(:transaction_record, :credit, account: account, amount: 200, booking_date: bom.prev_month(2) + 9.days)

      get api_v1_statistics_path, params: this_month_params, as: :json
      fc = response.parsed_body["forecast"]

      expect(fc["avg_window_months"]).to eq(2)             # empty months NOT averaged in
      expect(fc["variable_expenses"].to_f).to eq(-300.0)   # −600 ÷ 2
      expect(fc["variable_income"].to_f).to eq(100.0)      # +200 ÷ 2
    end

    # Window-start clamp (user rule 2026-06-10): never average a period the DATA-WEAKEST
    # in-scope account didn't cover. A long-history account averaged against a freshly-added
    # one must clamp to the YOUNGEST account's first month — else old months (which the young
    # account, e.g. a later-added Giro, never covered) skew the rate / leak phantom income.
    it "clamps the variable window to the youngest in-scope account's first month" do
      old_acc = create(:account, bank_connection: bc, balance_amount: 1000)
      new_acc = create(:account, bank_connection: bc, balance_amount: 500)
      bom = Date.current.beginning_of_month
      # old account: a non-recurring debit in each of the last 4 full months
      (1..4).each { |i| create(:transaction_record, account: old_acc, amount: -100, booking_date: bom.prev_month(i) + 9.days) }
      # young account: only the most-recent full month → window must clamp to it (÷1, not ÷4)
      create(:transaction_record, account: new_acc, amount: -300, booking_date: bom.prev_month(1) + 9.days)

      get api_v1_statistics_path, params: this_month_params, as: :json
      fc = response.parsed_body["forecast"]

      expect(fc["avg_window_months"]).to eq(1)             # clamped to the young account's 1 month, not 4
      expect(fc["variable_expenses"].to_f).to eq(-400.0)   # only month −1: −100 (old) + −300 (new), ÷1
    end

    # upcoming = active in-scope series with next_expected_on in the next 30 days,
    # ONE row per series, sorted by date asc; upcoming_total = Σ signed amount.
    it "lists upcoming payments within 30 days, one row per series, sorted, with a signed total" do
      account = create(:account, bank_connection: bc, balance_amount: 5000)
      soon_out = create(:recurring_series, user: user, direction: "outflow", canonical_name: "Netflix",
                                           expected_amount: -15, next_expected_on: Date.current + 5)
      create(:transaction_record, account: account, amount: -15, recurring_series: soon_out, booking_date: Date.current - 25)
      soon_in = create(:recurring_series, :inflow, user: user, canonical_name: "Gehalt",
                                          expected_amount: 2000, next_expected_on: Date.current + 2)
      create(:transaction_record, :credit, account: account, amount: 2000, recurring_series: soon_in, booking_date: Date.current - 28)
      # outside the 30-day window → excluded.
      later = create(:recurring_series, user: user, direction: "outflow", canonical_name: "Yearly Insurance",
                                        cadence: "yearly", cadence_days: 365, expected_amount: -120, next_expected_on: Date.current + 200)
      create(:transaction_record, account: account, amount: -120, recurring_series: later, booking_date: Date.current - 160)

      get api_v1_statistics_path, params: this_month_params, as: :json
      up = response.parsed_body["forecast"]["upcoming"]

      expect(up.map { |u| u["name"] }).to eq(["Gehalt", "Netflix"])       # sorted by date asc
      expect(up.map { |u| u["direction"] }).to eq(["inflow", "outflow"])
      expect(up.first).to include("date" => (Date.current + 2).iso8601, "amount" => "2000.0")
      expect(response.parsed_body["forecast"]["upcoming_total"].to_f).to eq(1985.0)  # 2000 + (-15)
    end

    # current_balance == the dashboard's total_balance for the SAME scope.
    it "reports current_balance equal to the dashboard total_balance per scope" do
      privat = create(:account, bank_connection: bc, balance_amount: 1234.56, shared: false)
      gemein = create(:account, bank_connection: bc, balance_amount: 800.00, shared: true)

      get api_v1_dashboard_path, params: { scope: "familie" }, as: :json
      dash_familie = response.parsed_body["total_balance"].to_f
      get api_v1_statistics_path, params: this_month_params.merge(scope: "familie"), as: :json
      expect(response.parsed_body["forecast"]["current_balance"].to_f).to eq(dash_familie)
      expect(response.parsed_body["forecast"]["current_balance"].to_f).to eq(2034.56)

      get api_v1_dashboard_path, params: { scope: "privat" }, as: :json
      dash_privat = response.parsed_body["total_balance"].to_f
      get api_v1_statistics_path, params: this_month_params.merge(scope: "privat"), as: :json
      expect(response.parsed_body["forecast"]["current_balance"].to_f).to eq(dash_privat)
      expect(response.parsed_body["forecast"]["current_balance"].to_f).to eq(1234.56)
    end

    # Liquide vs Gesamt lens (2026-06-11): the runway projection splits into a liquid
    # base (spending accounts) and the net-worth total. liquid_balance drops the
    # investment/savings accounts by role; current_balance keeps them.
    it "liquid_balance excludes investment/savings accounts (kreditkarte stays)" do
      create(:account, bank_connection: bc, balance_amount: 2000, role: "giro", role_locked: true)
      create(:account, bank_connection: bc, balance_amount: 9000, role: "investment", role_locked: true)
      create(:account, bank_connection: bc, balance_amount: -500, role: "kreditkarte", role_locked: true)

      get api_v1_statistics_path, params: this_month_params, as: :json
      fc = response.parsed_body["forecast"]
      expect(fc["current_balance"].to_f).to eq(10500.0)  # 2000 + 9000 − 500
      expect(fc["liquid_balance"].to_f).to eq(1500.0)     # investment dropped; card kept
    end

    # No investment/savings account ⇒ the lens collapses (liquid == total).
    it "collapses liquid to total when there is no investment/savings account" do
      create(:account, bank_connection: bc, balance_amount: 1234.56, role: "giro", role_locked: true)
      get api_v1_statistics_path, params: this_month_params, as: :json
      fc = response.parsed_body["forecast"]
      expect(fc["liquid_balance"]).to eq(fc["current_balance"])
      expect(fc["liquid_net"]).to eq(fc["total_net"])
    end

    # "Works with Sparplan": a recurring giro→investment transfer is NETTED in the
    # total (net-worth) lens but is a real OUTFLOW in the liquid lens (investment is
    # outside it), so the liquid runway drains by the savings rate. Falls straight out
    # of the scope machinery — liquid_projection runs flow_bucket with the liquid ids,
    # so the giro leg (counterpart out of the lens) buckets as an expense.
    it "counts a recurring giro→investment Sparplan as a liquid outflow, neutral in total" do
      giro   = create(:account, bank_connection: bc, balance_amount: 1000, role: "giro", role_locked: true)
      invest = create(:account, bank_connection: bc, balance_amount: 5000, role: "investment", role_locked: true)
      plan = create(:recurring_series, user: user, direction: "outflow", canonical_name: "Sparplan", expected_amount: -100)
      g = SecureRandom.uuid
      create(:transaction_record, account: giro, amount: -100, recurring_series: plan,
                                  booking_date: Date.current - 3, transfer_group_id: g, transfer_counterpart_account: invest)
      create(:transaction_record, account: invest, amount: 100, booking_date: Date.current - 3,
                                  transfer_group_id: g, transfer_counterpart_account: giro)

      get api_v1_statistics_path, params: this_month_params, as: :json
      fc = response.parsed_body["forecast"]
      expect(fc["current_balance"].to_f).to eq(6000.0)
      expect(fc["total_net"].to_f).to eq(0.0)       # Sparplan netted (internal transfer)
      expect(fc["liquid_balance"].to_f).to eq(1000.0)
      expect(fc["liquid_net"].to_f).to eq(-100.0)   # Sparplan now a real liquid outflow
    end
  end

  # Drill-down behind the "Variable Einnahmen/Ausgaben · Ø N Mt." ledger rows: the
  # individual non-recurring transactions over the SAME clamped window, plus the
  # till math (total ÷ months = average) that MUST reconcile to the forecast row.
  describe "variable_transactions (drill-down)" do
    it "lists the non-recurring debits that reconcile to forecast.variable_expenses" do
      account = create(:account, bank_connection: bc, balance_amount: 5000)
      fixed = create(:recurring_series, user: user, direction: "outflow", canonical_name: "Rent")
      3.times do |i|
        create(:transaction_record, account: account, amount: -300,
                                    booking_date: Date.current.beginning_of_month - (i * 30 + 5).days)
      end
      # recurring-linked debit and a current-month debit must BOTH be excluded.
      create(:transaction_record, account: account, amount: -1000, recurring_series: fixed,
                                  booking_date: Date.current.beginning_of_month - 5.days)
      create(:transaction_record, account: account, amount: -500, booking_date: Date.current)

      get variable_transactions_api_v1_statistics_path, params: { kind: "expenses" }, as: :json
      expect(response).to have_http_status(:ok)
      body = response.parsed_body

      expect(body["kind"]).to eq("expenses")
      expect(body["transactions"].size).to eq(3)
      expect(body["transactions"].map { |t| t["amount"].to_f }).to all(eq(-300.0))
      expect(body["total"].to_f).to eq(-900.0)
      expect(body["months"]).to eq(3)
      expect(body["average"].to_f).to eq(-300.0)

      # The drill-down average equals the ledger row it sits behind (the trust anchor).
      get api_v1_statistics_path, params: this_month_params, as: :json
      expect(body["average"].to_f).to eq(response.parsed_body["forecast"]["variable_expenses"].to_f)
    end

    it "lists non-recurring credits for kind=income, sorted newest first" do
      account = create(:account, bank_connection: bc, balance_amount: 5000)
      bom = Date.current.beginning_of_month
      old = create(:transaction_record, :credit, account: account, amount: 200, booking_date: bom.prev_month(2) + 9.days)
      recent = create(:transaction_record, :credit, account: account, amount: 50, booking_date: bom.prev_month(1) + 9.days)

      get variable_transactions_api_v1_statistics_path, params: { kind: "income" }, as: :json
      body = response.parsed_body

      expect(body["transactions"].map { |t| t["id"] }).to eq([recent.id, old.id])
      expect(body["transactions"].first).to include("category", "account_name", "remittance")
    end

    it "defaults to expenses for an unknown kind and honours scope" do
      privat = create(:account, bank_connection: bc, balance_amount: 1000, shared: false)
      gemein = create(:account, bank_connection: bc, balance_amount: 1000, shared: true)
      bom = Date.current.beginning_of_month
      create(:transaction_record, account: privat, amount: -100, booking_date: bom.prev_month(1) + 9.days)
      create(:transaction_record, account: gemein, amount: -400, booking_date: bom.prev_month(1) + 9.days)

      get variable_transactions_api_v1_statistics_path, params: { scope: "privat" }, as: :json
      body = response.parsed_body
      expect(body["kind"]).to eq("expenses")
      expect(body["transactions"].map { |t| t["amount"].to_f }).to eq([-100.0])

      get variable_transactions_api_v1_statistics_path, as: :json
      expect(response.parsed_body["transactions"].map { |t| t["amount"].to_f }).to contain_exactly(-100.0, -400.0)
    end

    it "requires authentication" do
      delete session_path, as: :json
      get variable_transactions_api_v1_statistics_path, params: { kind: "expenses" }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    # §4a — the reconciliation anchor: a matched internal transfer whose counterpart
    # is also in scope nets to zero, so it must be absent from BOTH the drill-down
    # list AND the forecast row the modal reconciles to (in_scope, via variable_window).
    it "excludes in-scope internal transfers, staying reconciled to the ledger row" do
      a = create(:account, bank_connection: bc, balance_amount: 5000)
      b = create(:account, bank_connection: bc, balance_amount: 5000)
      bom = Date.current.beginning_of_month
      real = create(:transaction_record, account: a, amount: -300, booking_date: bom.prev_month(1) + 9.days)
      # a matched transfer pair between two in-scope accounts (net zero) — both legs hidden.
      g = "grp-1"
      out = create(:transaction_record, account: a, amount: -200, booking_date: bom.prev_month(1) + 10.days,
                                        transfer_group_id: g, transfer_counterpart_account: b)
      create(:transaction_record, :credit, account: b, amount: 200, booking_date: bom.prev_month(1) + 10.days,
                                            transfer_group_id: g, transfer_counterpart_account: a)

      get variable_transactions_api_v1_statistics_path, params: { kind: "expenses" }, as: :json
      ids = response.parsed_body["transactions"].map { |t| t["id"] }
      expect(ids).to eq([real.id])           # the transfer leg is netted out
      expect(ids).not_to include(out.id)
      avg = response.parsed_body["average"].to_f

      get api_v1_statistics_path, params: this_month_params, as: :json
      expect(avg).to eq(response.parsed_body["forecast"]["variable_expenses"].to_f)
    end

    it "never exposes another user's transactions" do
      other = create(:user, password: "password123")
      other_acc = create(:account, bank_connection: create(:bank_connection, user: other), balance_amount: 999)
      create(:transaction_record, account: other_acc, amount: -500, booking_date: Date.current.beginning_of_month.prev_month(1) + 9.days)
      mine = create(:account, bank_connection: bc, balance_amount: 100)
      create(:transaction_record, account: mine, amount: -10, booking_date: Date.current.beginning_of_month.prev_month(1) + 9.days)

      get variable_transactions_api_v1_statistics_path, params: { kind: "expenses" }, as: :json
      body = response.parsed_body
      expect(body["transactions"].map { |t| t["amount"].to_f }).to eq([-10.0])
    end
  end
end
