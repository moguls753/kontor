require "rails_helper"

RSpec.describe "easybank login + mTAN", type: :request do
  let(:user) { create(:user, password: "password123") }
  let(:easybank_client) { instance_double(EasyBank::ScraperClient) }

  before do
    post session_path, params: { email_address: user.email_address, password: "password123" }, as: :json
    allow(EasyBank::ScraperClient).to receive(:new).and_return(easybank_client)
  end

  describe "POST /api/v1/bank_connections (easybank)" do
    before { create(:easybank_credential, user: user) }

    it "authorizes immediately, creates the account and syncs when no mTAN is needed" do
      allow(easybank_client).to receive(:login).and_return(easybank_sync_response)

      expect {
        post api_v1_bank_connections_path, params: { provider: "easybank" }, as: :json
      }.to have_enqueued_job(SyncAccountsJob)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["status"]).to eq("authorized")
      expect(body).not_to have_key("mtan_required")

      bc = user.bank_connections.find_by(provider: "easybank")
      expect(bc.institution_id).to eq("easybank")
      expect(bc.status).to eq("authorized")
      expect(bc.accounts.find_by(account_uid: "easybank")).to be_present
    end

    it "returns an mTAN challenge and keeps the connection pending when login needs an SMS code" do
      allow(easybank_client).to receive(:login).and_raise(
        EasyBank::MtanRequired.new(
          "SMS sent",
          pairing_id: "pid-1", masked_phone: "+49 *** 1234", reference: "ref-9", expires_in: 300
        )
      )

      post api_v1_bank_connections_path, params: { provider: "easybank" }, as: :json

      expect(response).to have_http_status(:created)
      body = response.parsed_body
      expect(body["mtan_required"]).to be true
      expect(body["pairing_id"]).to eq("pid-1")
      expect(body["masked_phone"]).to eq("+49 *** 1234")
      expect(body["expires_in"]).to eq(300)

      bc = user.bank_connections.find_by(provider: "easybank")
      expect(bc.status).to eq("pending")
      expect(bc.accounts).to be_empty
    end

    it "reuses the single connection instead of accumulating orphans" do
      allow(easybank_client).to receive(:login).and_return(easybank_sync_response)

      2.times { post api_v1_bank_connections_path, params: { provider: "easybank" }, as: :json }

      expect(user.bank_connections.where(provider: "easybank").count).to eq(1)
    end

    it "surfaces a rejected login as 422 and marks the connection in error" do
      allow(easybank_client).to receive(:login).and_raise(EasyBank::LoginFailed.new("bad credentials"))

      post api_v1_bank_connections_path, params: { provider: "easybank" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to eq("login_failed")
      bc = user.bank_connections.find_by(provider: "easybank")
      expect(bc.status).to eq("error")
    end

    it "returns 422 when easybank is not configured" do
      user.easybank_credential.destroy!

      post api_v1_bank_connections_path, params: { provider: "easybank" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "POST /api/v1/bank_connections/:id/confirm_2fa (easybank)" do
    let!(:credential) { create(:easybank_credential, user: user) }
    let(:bc) { create(:bank_connection, :easybank, user: user, status: "pending") }

    it "finishes pairing: creates the account, authorizes, records last_paired_at and syncs" do
      allow(easybank_client).to receive(:submit_mtan).and_return("status" => "ok")

      expect {
        post confirm_2fa_api_v1_bank_connection_path(bc), params: { pairing_id: "pid-1", code: "123456" }, as: :json
      }.to have_enqueued_job(SyncAccountsJob)

      expect(response).to have_http_status(:ok)
      expect(bc.reload.status).to eq("authorized")
      expect(bc.accounts.find_by(account_uid: "easybank")).to be_present
      expect(credential.reload.last_paired_at).to be_present
    end

    it "stays retryable (422) on a wrong mTAN and does not authorize" do
      allow(easybank_client).to receive(:submit_mtan).and_raise(EasyBank::MtanFailed.new("wrong code"))

      post confirm_2fa_api_v1_bank_connection_path(bc), params: { pairing_id: "pid-1", code: "000000" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to eq("mtan_failed")
      expect(bc.reload.status).to eq("pending")
    end
  end

  describe "POST /api/v1/bank_connections/:id/reconnect (easybank)" do
    it "re-initiates login on an expired connection" do
      create(:easybank_credential, user: user)
      bc = create(:bank_connection, :easybank, user: user, status: "expired")
      allow(easybank_client).to receive(:login).and_return(easybank_sync_response)

      expect {
        post reconnect_api_v1_bank_connection_path(bc), as: :json
      }.to have_enqueued_job(SyncAccountsJob)

      expect(response).to have_http_status(:ok)
      expect(bc.reload.status).to eq("authorized")
    end
  end
end
