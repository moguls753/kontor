require "rails_helper"

RSpec.describe "Api::V1::BankConnections", type: :request do
  let(:user) { create(:user, password: "password123") }
  before { post session_path, params: { email_address: user.email_address, password: "password123" }, as: :json }

  describe "POST /api/v1/bank_connections (EB)" do
    it "creates pending connection and returns redirect_url" do
      create(:enable_banking_credential, user: user)
      eb_client = instance_double(EnableBanking::Client)
      allow(EnableBanking::Client).to receive(:new).and_return(eb_client)
      allow(eb_client).to receive(:start_authorization).and_return(eb_auth_response)

      post api_v1_bank_connections_path, params: {
        provider: "enable_banking", institution_id: "SPARKASSE_DE", country_code: "DE"
      }, as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["redirect_url"]).to be_present
      expect(BankConnection.last.status).to eq("pending")
    end
  end

  describe "POST /api/v1/bank_connections (GC)" do
    it "creates pending connection and returns redirect_url" do
      create(:go_cardless_credential, :with_token, user: user)
      gc_client = instance_double(GoCardless::Client)
      allow(GoCardless::Client).to receive(:new).and_return(gc_client)
      allow(gc_client).to receive(:create_requisition).and_return(gc_requisition_response)

      post api_v1_bank_connections_path, params: {
        provider: "gocardless", institution_id: "TOMORROW_SOBKDEBB", country_code: "DE"
      }, as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["redirect_url"]).to include("gocardless.com")
      expect(BankConnection.last.requisition_id).to eq("req-uuid-1234")
    end
  end

  describe "GET /callback (EB)" do
    it "completes authorization and redirects" do
      create(:enable_banking_credential, user: user)
      bc = create(:bank_connection, :pending, user: user, provider: "enable_banking")
      eb_client = instance_double(EnableBanking::Client)
      allow(EnableBanking::Client).to receive(:new).and_return(eb_client)
      allow(eb_client).to receive(:create_session).and_return(eb_session_response)

      get callback_api_v1_bank_connection_path(bc), params: { code: "auth-code" }

      expect(response).to redirect_to("/?bank_connection_success=#{bc.id}")
      bc.reload
      expect(bc.status).to eq("authorized")
      expect(bc.accounts.count).to eq(2)
      # IBAN must be extracted from the nested EB resource — account_id.iban for
      # the first account, all_account_ids fallback for the second.
      expect(bc.accounts.find_by(account_uid: "account-uid-1").iban).to eq("DE89370400440532013000")
      expect(bc.accounts.find_by(account_uid: "account-uid-2").iban).to eq("DE27100777770209299700")
    end

    # Blocker 1: the FIRST sync after a new connection is authorized is an ingest
    # path too — it must enqueue the post-sync pipeline so the freshly synced rows
    # are categorized / transfer-matched / detected without waiting for the next
    # 6h fan-out.
    it "enqueues the post-sync pipeline" do
      create(:enable_banking_credential, user: user)
      bc = create(:bank_connection, :pending, user: user, provider: "enable_banking")
      eb_client = instance_double(EnableBanking::Client)
      allow(EnableBanking::Client).to receive(:new).and_return(eb_client)
      allow(eb_client).to receive(:create_session).and_return(eb_session_response)

      expect {
        get callback_api_v1_bank_connection_path(bc), params: { code: "auth-code" }
      }.to have_enqueued_job(ProcessAccountDataJob).with(user.id)
    end
  end

  describe "GET /callback with error" do
    it "marks connection as error and redirects" do
      bc = create(:bank_connection, :pending, user: user)

      get callback_api_v1_bank_connection_path(bc), params: { error: "access_denied" }

      expect(response).to redirect_to("/?bank_connection_error=#{bc.id}")
      expect(bc.reload.status).to eq("error")
    end
  end

  describe "GET /api/v1/bank_connections" do
    it "returns user connections with accounts" do
      bc = create(:bank_connection, user: user)
      create(:account, bank_connection: bc)

      get api_v1_bank_connections_path, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.first["accounts"].length).to eq(1)
    end
  end

  describe "DELETE /api/v1/bank_connections/:id" do
    it "destroys connection" do
      bc = create(:bank_connection, user: user)
      delete api_v1_bank_connection_path(bc), as: :json
      expect(response).to have_http_status(:no_content)
      expect(BankConnection.find_by(id: bc.id)).to be_nil
    end

    it "enqueues the post-sync pipeline so orphaned transfer legs are re-evaluated" do
      bc = create(:bank_connection, user: user)
      expect {
        delete api_v1_bank_connection_path(bc), as: :json
      }.to have_enqueued_job(ProcessAccountDataJob).with(user.id)
    end
  end

  # Blocker 1: every ingest path must enqueue the post-sync pipeline so the matcher
  # actually runs. Before this fix the manual sync never matched transfers and the
  # dashboard double-counted internal transfers for ~24h.
  describe "POST /api/v1/bank_connections/:id/sync (pipeline)" do
    include ActiveJob::TestHelper

    it "queues the pipeline whose matcher excludes both transfer legs from the dashboard" do
      bc = create(:bank_connection, user: user)
      giro = create(:account, bank_connection: bc, iban: "DE89370400440532013000", balance_amount: 1000)
      spar = create(:account, bank_connection: bc, iban: "DE12345678901234567890", balance_amount: 500)

      # Two unmatched counter-legs, as if just ingested by the sync. The dashboard
      # would double-count them (a -70 expense AND a +70 income) until matched.
      create(:transaction_record, account: giro, amount: -70, booking_date: Date.current,
                                  creditor_iban: spar.iban)
      create(:transaction_record, :credit, account: spar, amount: 70, booking_date: Date.current,
                                           debtor_iban: giro.iban)

      # Sanity: with no pipeline run yet the legs are unmatched → both count.
      get api_v1_dashboard_path, as: :json
      expect(response.parsed_body["expenses"]).to eq("-70.0")
      expect(response.parsed_body["income"]).to eq("70.0")

      # The sync action enqueues the per-connection job AND the user-wide pipeline.
      expect {
        post sync_api_v1_bank_connection_path(bc), as: :json
      }.to have_enqueued_job(ProcessAccountDataJob).with(user.id)
      expect(response.parsed_body).to eq("queued" => true)

      # Run only the pipeline (not the per-connection SyncAccountsJob, which would
      # hit the live bank). This is what couples sync → matcher.
      perform_enqueued_jobs(only: ProcessAccountDataJob)

      # The dashboard read uses NO inline matcher — it relies on the pipeline having
      # written transfer_group_id. Both legs are now excluded.
      get api_v1_dashboard_path, as: :json
      body = response.parsed_body
      expect(body["expenses"]).to eq("0.0")
      expect(body["income"]).to eq("0.0")
    end
  end
end
