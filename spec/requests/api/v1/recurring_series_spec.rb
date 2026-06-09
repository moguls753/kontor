require "rails_helper"

RSpec.describe "Api::V1::RecurringSeries", type: :request do
  let(:user) { create(:user, password: "password123") }
  let(:bc) { create(:bank_connection, user: user) }
  let(:account) { create(:account, bank_connection: bc, iban: nil) }

  def login(u = user)
    post session_path, params: { email_address: u.email_address, password: "password123" }, as: :json
  end

  describe "GET /api/v1/recurring (index)" do
    before { login }

    it "returns the user's own series and not another user's" do
      mine = create(:recurring_series, user: user, canonical_name: "Spotify")
      other = create(:recurring_series, user: create(:user), canonical_name: "Netflix")

      get api_v1_recurring_index_path, as: :json

      ids = response.parsed_body["series"].map { |s| s["id"] }
      expect(ids).to include(mine.id)
      expect(ids).not_to include(other.id)
    end

    it "shows a NULL-merchant_type series by default (B1′)" do
      s = create(:recurring_series, user: user, merchant_type: nil)

      get api_v1_recurring_index_path, as: :json

      expect(response.parsed_body["series"].map { |x| x["id"] }).to include(s.id)
    end

    it "hides consumption-type series (groceries/shopping/transport) by default" do
      hidden = RecurringSeries::CONSUMPTION_TYPES.map do |type|
        create(:recurring_series, user: user, merchant_type: type, canonical_name: type.titleize)
      end

      get api_v1_recurring_index_path, as: :json

      ids = response.parsed_body["series"].map { |x| x["id"] }
      hidden.each { |s| expect(ids).not_to include(s.id) }
    end

    it "filters out a shared-account-only series in ?scope=privat" do
      personal_acct = create(:account, bank_connection: bc, shared: false)
      shared_acct   = create(:account, bank_connection: bc, shared: true)

      mine = create(:recurring_series, user: user, canonical_name: "Spotify Privat")
      create(:transaction_record, account: personal_acct, recurring_series: mine, amount: -12.99)

      gemein = create(:recurring_series, user: user, canonical_name: "Netflix Familie",
                                         fingerprint: "scopegemein00001")
      create(:transaction_record, account: shared_acct, recurring_series: gemein, amount: -15.99)

      get api_v1_recurring_index_path, params: { scope: "privat" }, as: :json
      ids = response.parsed_body["series"].map { |x| x["id"] }
      expect(ids).to include(mine.id)
      expect(ids).not_to include(gemein.id)

      get api_v1_recurring_index_path, params: { scope: "familie" }, as: :json
      ids = response.parsed_body["series"].map { |x| x["id"] }
      expect(ids).to include(mine.id, gemein.id)
    end

    # §4 fix — a personal→personal transfer has BOTH legs in scope, so the §4a net-zero
    # exclusion would leave zero in-scope members. The "privat" lens must key on account
    # membership only, so the transfer series stays visible in ?scope=privat (Transfers tab).
    it "keeps a personal Giro→Sparkonto transfer series visible in ?scope=privat" do
      giro     = create(:account, bank_connection: bc, shared: false, role: "giro", role_locked: true)
      sparkonto = create(:account, bank_connection: bc, shared: false, role: "sparkonto", role_locked: true)

      transfer = create(:recurring_series, user: user, direction: "outflow", canonical_name: "Sparplan Privat")
      create(:transaction_record, account: giro, recurring_series: transfer, amount: -250,
        transfer_group_id: "tg-priv-save", transfer_counterpart_account: sparkonto)

      get api_v1_recurring_index_path, params: { scope: "privat", include_transfers: "true" }, as: :json
      ids = response.parsed_body["series"].map { |x| x["id"] }
      expect(ids).to include(transfer.id)
    end

    it "keeps a subscription series visible (consumption filter only hides shopping/groceries/transport)" do
      sub = create(:recurring_series, user: user, merchant_type: "subscription", canonical_name: "Crowdfarming")

      get api_v1_recurring_index_path, as: :json

      expect(response.parsed_body["series"].map { |x| x["id"] }).to include(sub.id)
    end

    it "keeps consumption-type series hidden even with include_transfers=true" do
      groceries = create(:recurring_series, user: user, merchant_type: "groceries", canonical_name: "Penny")

      get api_v1_recurring_index_path, params: { include_transfers: "true" }, as: :json

      expect(response.parsed_body["series"].map { |x| x["id"] }).not_to include(groceries.id)
    end

    it "hides a matched-transfer series unless include_transfers=true (live transfer_group_id, not a sticky column)" do
      other = create(:account, bank_connection: bc, role: "giro", role_locked: true)
      transfer = create(:recurring_series, user: user, direction: "outflow", canonical_name: "Own Transfer")
      create(:transaction_record, account: account, recurring_series: transfer, amount: -500,
        transfer_group_id: "tg-own", transfer_counterpart_account: other)

      get api_v1_recurring_index_path, as: :json
      expect(response.parsed_body["series"].map { |x| x["id"] }).not_to include(transfer.id)

      get api_v1_recurring_index_path, params: { include_transfers: "true" }, as: :json
      expect(response.parsed_body["series"].map { |x| x["id"] }).to include(transfer.id)
    end

    # Three flow buckets (expense / income / transfer) are derived server-side from
    # direction + own-account membership and surfaced as flow_bucket.
    it "tags a matched internal transfer series as transfer via transfer_group_id (not a name heuristic)" do
      other = create(:account, bank_connection: bc, role: "giro", role_locked: true)
      transfer = create(:recurring_series, user: user, direction: "outflow", canonical_name: "Umbuchung")
      create(:transaction_record, account: account, recurring_series: transfer, amount: -500,
        transfer_group_id: "tg1", transfer_counterpart_account: other)

      # hidden by default (transfer), surfaced with include_transfers
      get api_v1_recurring_index_path, as: :json
      expect(response.parsed_body["series"].map { |x| x["id"] }).not_to include(transfer.id)

      get api_v1_recurring_index_path, params: { include_transfers: "true" }, as: :json
      row = response.parsed_body["series"].find { |x| x["id"] == transfer.id }
      expect(row["flow_bucket"]).to eq("transfer")
    end

    it "puts an external recurring outflow (incl. savings plans like Scalable) in the expense bucket" do
      series = create(:recurring_series, user: user, direction: "outflow", canonical_name: "Scalable Capital")
      create(:transaction_record, account: account, recurring_series: series, amount: -150)

      get api_v1_recurring_index_path, as: :json
      row = response.parsed_body["series"].find { |x| x["id"] == series.id }
      expect(row["flow_bucket"]).to eq("expense")
    end

    it "puts an external recurring inflow in the income bucket (category does not change the bucket)" do
      shared = create(:account, bank_connection: bc, shared: true, role_locked: true)
      sparen_cat = create(:category, user: user, name: "Sparen")
      series = create(:recurring_series, :inflow, user: user, canonical_name: "Ansparen", category: sparen_cat)
      create(:transaction_record, account: shared, recurring_series: series, amount: 300)

      get api_v1_recurring_index_path, as: :json
      row = response.parsed_body["series"].find { |x| x["id"] == series.id }
      expect(row["flow_bucket"]).to eq("income")
    end

    it "hides dismissed series by default" do
      dismissed = create(:recurring_series, :dismissed, user: user)

      get api_v1_recurring_index_path, as: :json
      expect(response.parsed_body["series"].map { |x| x["id"] }).not_to include(dismissed.id)
    end

    it "hides ended series by default but shows them with ?status=ended" do
      ended = create(:recurring_series, :monthly, user: user, status: "ended", canonical_name: "Cancelled Sub")

      get api_v1_recurring_index_path, as: :json
      expect(response.parsed_body["series"].map { |x| x["id"] }).not_to include(ended.id)

      get api_v1_recurring_index_path, params: { status: "ended" }, as: :json
      expect(response.parsed_body["series"].map { |x| x["id"] }).to include(ended.id)
    end

  end

  describe "POST /api/v1/recurring/detect" do
    include ActiveJob::TestHelper
    before { login }

    it "enqueues the pipeline async (no inline blocking) and returns queued" do
      expect {
        post detect_api_v1_recurring_index_path, as: :json
      }.to have_enqueued_job(ProcessAccountDataJob).with(user.id)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("queued" => true)
    end

    it "creates series from seeded transactions once the pipeline runs" do
      4.times do |i|
        create(:transaction_record, account: account, amount: -12.99,
          creditor_name: "Spotify", creditor_iban: nil,
          booking_date: Date.current - (i * 30))
      end

      expect {
        perform_enqueued_jobs { post detect_api_v1_recurring_index_path, as: :json }
      }.to change { user.recurring_series.count }.from(0).to(1)
    end
  end

  describe "PATCH /api/v1/recurring/:id (update)" do
    before { login }

    it "confirms and sets a category" do
      series = create(:recurring_series, user: user)
      category = create(:category, user: user)

      patch api_v1_recurring_path(series),
        params: { recurring_series: { user_confirmed: true, category_id: category.id } }, as: :json

      expect(response).to have_http_status(:ok)
      expect(series.reload.user_confirmed).to be(true)
      expect(series.category_id).to eq(category.id)
    end

    # #17 — status allowlist: only active/dismissed are user-settable; "ended" is
    # a system-only state and must be dropped, not applied.
    it "ignores a status change to the system-only 'ended' state" do
      series = create(:recurring_series, user: user, status: "active")

      patch api_v1_recurring_path(series),
        params: { recurring_series: { status: "ended" } }, as: :json

      expect(response).to have_http_status(:ok)
      expect(series.reload.status).to eq("active")
    end

    it "allows a status change to 'dismissed'" do
      series = create(:recurring_series, user: user, status: "active")

      patch api_v1_recurring_path(series),
        params: { recurring_series: { status: "dismissed" } }, as: :json

      expect(response).to have_http_status(:ok)
      expect(series.reload.status).to eq("dismissed")
    end

    # #4 guard — a category_id owned by ANOTHER user must not be applied.
    it "does not apply a category_id belonging to another user" do
      series = create(:recurring_series, user: user)
      foreign_category = create(:category, user: create(:user))

      patch api_v1_recurring_path(series),
        params: { recurring_series: { category_id: foreign_category.id } }, as: :json

      expect(series.reload.category_id).to be_nil
    end

    # #9 — renaming canonical_name must recompute the fingerprint (model before_save)
    # to fingerprint_for(direction, currency, new_name) — never leave it stale.
    it "recomputes the fingerprint when canonical_name is renamed" do
      series = create(:recurring_series, user: user, canonical_name: "Spotify",
        direction: "outflow", currency: "EUR")
      old_fp = series.fingerprint

      patch api_v1_recurring_path(series),
        params: { recurring_series: { canonical_name: "Spotify AB" } }, as: :json

      expect(response).to have_http_status(:ok)
      series.reload
      expect(series.canonical_name).to eq("Spotify AB")
      expect(series.fingerprint).to eq(
        RecurringSeries.fingerprint_for("outflow", "EUR", "Spotify AB")
      )
      expect(series.fingerprint).not_to eq(old_fp)
    end
  end

  describe "DELETE /api/v1/recurring/:id (destroy)" do
    before { login }

    it "soft-dismisses the series and nullifies member links" do
      series = create(:recurring_series, user: user)
      tx = create(:transaction_record, account: account, recurring_series: series)

      delete api_v1_recurring_path(series), as: :json

      expect(response).to have_http_status(:no_content)
      expect(series.reload.status).to eq("dismissed")
      expect(tx.reload.recurring_series_id).to be_nil
    end
  end

  describe "authentication" do
    it "returns 401 without a session" do
      get api_v1_recurring_index_path, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
