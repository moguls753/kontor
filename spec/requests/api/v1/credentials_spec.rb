require "rails_helper"

RSpec.describe "Api::V1::Credentials", type: :request do
  let(:user) { create(:user, password: "password123") }
  before { post session_path, params: { email_address: user.email_address, password: "password123" }, as: :json }

  describe "GET /api/v1/credentials" do
    it "returns configured state for both providers" do
      create(:enable_banking_credential, user: user)
      get api_v1_credentials_path, as: :json
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["enable_banking"]["configured"]).to be true
      expect(body["gocardless"]["configured"]).to be false
    end

    it "masks the Trade Republic phone and never returns the PIN" do
      create(:trade_republic_credential, user: user)
      get api_v1_credentials_path, as: :json
      body = response.parsed_body
      expect(body["trade_republic"]["configured"]).to be true
      expect(body["trade_republic"]["phone_number_masked"]).to start_with("+49")
      expect(response.body).not_to include("1234")
      expect(response.body).not_to include("15112345678")
    end

    it "reports easybank as not configured by default" do
      get api_v1_credentials_path, as: :json
      expect(response.parsed_body["easybank"]["configured"]).to be false
    end

    it "masks the easybank username and never returns the password" do
      create(:easybank_credential, user: user, username: "alice.banks", password: "s3cret-pass")
      get api_v1_credentials_path, as: :json
      body = response.parsed_body
      expect(body["easybank"]["configured"]).to be true
      expect(body["easybank"]["username_masked"]).to be_present
      expect(response.body).not_to include("alice.banks")
      expect(response.body).not_to include("s3cret-pass")
    end
  end

  describe "POST /api/v1/credentials" do
    it "creates Enable Banking credentials" do
      post api_v1_credentials_path, params: {
        provider: "enable_banking",
        credentials: { app_id: "test-app", private_key_pem: OpenSSL::PKey::RSA.generate(2048).to_pem }
      }, as: :json
      expect(response).to have_http_status(:created)
      expect(user.reload.enable_banking_credential).to be_present
    end

    it "creates GoCardless credentials" do
      post api_v1_credentials_path, params: {
        provider: "gocardless",
        credentials: { secret_id: "sid", secret_key: "skey" }
      }, as: :json
      expect(response).to have_http_status(:created)
      expect(user.reload.go_cardless_credential).to be_present
    end

    it "creates Trade Republic credentials" do
      post api_v1_credentials_path, params: {
        provider: "trade_republic",
        credentials: { phone_number: "+4915112345678", pin: "1234" }
      }, as: :json
      expect(response).to have_http_status(:created)
      expect(user.reload.trade_republic_credential).to be_present
    end

    it "creates easybank credentials" do
      post api_v1_credentials_path, params: {
        provider: "easybank",
        credentials: { username: "moguls753", password: "s3cret-pass" }
      }, as: :json
      expect(response).to have_http_status(:created)
      expect(user.reload.easybank_credential).to be_present
    end

    it "rejects a second easybank credential as already configured" do
      create(:easybank_credential, user: user)
      post api_v1_credentials_path, params: {
        provider: "easybank", credentials: { username: "other", password: "pw" }
      }, as: :json
      expect(response).to have_http_status(:conflict)
    end

    it "rejects missing params" do
      post api_v1_credentials_path, params: { provider: "enable_banking", credentials: { app_id: "" } }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "PATCH /api/v1/credentials" do
    it "updates easybank credentials" do
      create(:easybank_credential, user: user, username: "old.name")
      patch api_v1_credentials_path, params: {
        provider: "easybank", credentials: { username: "new.name", password: "new-pass" }
      }, as: :json
      expect(response).to have_http_status(:ok)
      expect(user.reload.easybank_credential.username).to eq("new.name")
    end

    it "404s updating an unconfigured easybank credential" do
      patch api_v1_credentials_path, params: {
        provider: "easybank", credentials: { username: "x", password: "y" }
      }, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  it "returns 401 when not logged in" do
    delete session_path, as: :json
    get api_v1_credentials_path, as: :json
    expect(response).to have_http_status(:unauthorized)
  end
end
