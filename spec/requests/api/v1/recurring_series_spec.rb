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

    it "hides transfer-tagged series unless include_transfers=true" do
      transfer = create(:recurring_series, user: user, merchant_type: "transfer", canonical_name: "Own Transfer")

      get api_v1_recurring_index_path, as: :json
      expect(response.parsed_body["series"].map { |x| x["id"] }).not_to include(transfer.id)

      get api_v1_recurring_index_path, params: { include_transfers: "true" }, as: :json
      expect(response.parsed_body["series"].map { |x| x["id"] }).to include(transfer.id)
    end

    it "hides dismissed series by default" do
      dismissed = create(:recurring_series, :dismissed, user: user)

      get api_v1_recurring_index_path, as: :json
      expect(response.parsed_body["series"].map { |x| x["id"] }).not_to include(dismissed.id)
    end
  end

  describe "POST /api/v1/recurring/detect" do
    before { login }

    it "creates series from seeded transactions" do
      4.times do |i|
        create(:transaction_record, account: account, amount: -12.99,
          creditor_name: "Spotify", creditor_iban: nil,
          booking_date: Date.current - (i * 30))
      end

      expect {
        post detect_api_v1_recurring_index_path, as: :json
      }.to change { user.recurring_series.count }.from(0).to(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["detected"]).to eq(1)
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
