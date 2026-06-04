require "rails_helper"

RSpec.describe "Trade Republic pairing", type: :request do
  let(:user) { create(:user, password: "password123") }
  let(:tr_client) { instance_double(TradeRepublic::ScraperClient) }

  before do
    post session_path, params: { email_address: user.email_address, password: "password123" }, as: :json
    allow(TradeRepublic::ScraperClient).to receive(:new).and_return(tr_client)
  end

  describe "POST /api/v1/bank_connections (trade_republic)" do
    before { create(:trade_republic_credential, user: user) }

    it "starts pairing and returns a pairing_id with no redirect_url" do
      allow(tr_client).to receive(:pair_start).and_return(pairing_id: "pid", countdown_seconds: 60, channel: "push")

      post api_v1_bank_connections_path, params: { provider: "trade_republic" }, as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["pairing_id"]).to eq("pid")
      expect(response.parsed_body["redirect_url"]).to be_nil

      bc = user.bank_connections.find_by(provider: "trade_republic")
      expect(bc.institution_id).to eq("trade_republic")
      expect(bc.status).to eq("pending")
    end

    it "reuses the single connection instead of accumulating orphans" do
      allow(tr_client).to receive(:pair_start).and_return(pairing_id: "pid", countdown_seconds: 60, channel: "push")

      2.times { post api_v1_bank_connections_path, params: { provider: "trade_republic" }, as: :json }

      expect(user.bank_connections.where(provider: "trade_republic").count).to eq(1)
    end

    it "surfaces a rejected PIN as 422 without authorizing the connection" do
      allow(tr_client).to receive(:pair_start).and_raise(TradeRepublic::PairingFailedError.new("bad pin"))

      post api_v1_bank_connections_path, params: { provider: "trade_republic" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(user.bank_connections.where(provider: "trade_republic", status: "authorized")).to be_empty
    end
  end

  describe "POST /api/v1/bank_connections/:id/confirm_2fa" do
    let!(:credential) { create(:trade_republic_credential, user: user) }
    let(:bc) { create(:bank_connection, :trade_republic, user: user, status: "pending") }

    it "completes pairing: stores the session, creates the account and authorizes" do
      allow(tr_client).to receive(:pair_finish).and_return(session_blob: "blob-xyz")

      post confirm_2fa_api_v1_bank_connection_path(bc), params: { pairing_id: "pid", code: "1234" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(bc.reload.status).to eq("authorized")
      expect(bc.accounts.find_by(account_uid: "trade_republic")).to be_present
      expect(credential.reload.session_blob).to eq("blob-xyz")
      expect(credential.last_paired_at).to be_present
    end

    it "stays retryable (422) on a wrong code and does not authorize" do
      allow(tr_client).to receive(:pair_finish).and_raise(TradeRepublic::PairingFailedError.new("wrong code"))

      post confirm_2fa_api_v1_bank_connection_path(bc), params: { pairing_id: "pid", code: "0000" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(bc.reload.status).to eq("pending")
    end

    it "returns 410 when the pairing has expired (restart required)" do
      allow(tr_client).to receive(:pair_finish).and_raise(TradeRepublic::PairingExpiredError.new("expired"))

      post confirm_2fa_api_v1_bank_connection_path(bc), params: { pairing_id: "old", code: "1234" }, as: :json

      expect(response).to have_http_status(:gone)
    end
  end

  describe "POST /api/v1/bank_connections/:id/reconnect (trade_republic)" do
    it "re-initiates pairing and returns a fresh pairing_id" do
      create(:trade_republic_credential, user: user)
      bc = create(:bank_connection, :trade_republic, user: user, status: "expired")
      allow(tr_client).to receive(:pair_start).and_return(pairing_id: "pid2", countdown_seconds: 60, channel: "push")

      post reconnect_api_v1_bank_connection_path(bc), as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["pairing_id"]).to eq("pid2")
    end
  end
end
