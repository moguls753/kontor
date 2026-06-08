require "rails_helper"

RSpec.describe "PayPal connect + manual sync", type: :request do
  let(:user) { create(:user, password: "password123") }
  let(:paypal_client) { instance_double(Paypal::ScraperClient) }

  before do
    post session_path, params: { email_address: user.email_address, password: "password123" }, as: :json
    allow(Paypal::ScraperClient).to receive(:new).and_return(paypal_client)
  end

  describe "POST /api/v1/bank_connections (paypal)" do
    before { create(:paypal_credential, user: user) }

    it "establishes an authorized connection WITHOUT logging in at connect time" do
      expect(paypal_client).not_to receive(:sync)

      post api_v1_bank_connections_path, params: { provider: "paypal" }, as: :json

      expect(response).to have_http_status(:created)
      bc = user.bank_connections.find_by(provider: "paypal")
      expect(bc.institution_id).to eq("paypal")
      expect(bc.status).to eq("authorized")
    end

    it "reuses the single connection instead of accumulating orphans" do
      2.times { post api_v1_bank_connections_path, params: { provider: "paypal" }, as: :json }
      expect(user.bank_connections.where(provider: "paypal").count).to eq(1)
    end

    it "returns 422 when paypal is not configured" do
      user.paypal_credential.destroy!
      post api_v1_bank_connections_path, params: { provider: "paypal" }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "does NOT un-trip a tripped circuit breaker on a plain re-connect" do
      tripped = create(:bank_connection, :paypal, user: user, status: "error",
                       consecutive_failures: 3, error_message: "PayPal sync failed repeatedly. Reconnect to re-pair.")

      post api_v1_bank_connections_path, params: { provider: "paypal" }, as: :json

      expect(response).to have_http_status(:created)
      tripped.reload
      # The breaker must survive a plain create→sync; only an explicit reconnect clears it.
      expect(tripped.status).to eq("error")
      expect(tripped.consecutive_failures).to eq(3)
    end
  end

  describe "POST /api/v1/bank_connections/:id/sync (background) for paypal" do
    let!(:credential) { create(:paypal_credential, user: user) }
    let(:bc) { create(:bank_connection, :paypal, user: user, status: "authorized") }

    it "refuses to enqueue a PayPal connection on the background job" do
      expect {
        post sync_api_v1_bank_connection_path(bc), as: :json
      }.not_to have_enqueued_job(SyncAccountsJob)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to eq("manual_sync_only")
    end
  end

  describe "POST /api/v1/bank_connections/:id/sync_paypal" do
    let!(:credential) { create(:paypal_credential, user: user) }
    let(:bc) { create(:bank_connection, :paypal, user: user, status: "authorized") }

    it "syncs synchronously, ingests the activity and stays authorized" do
      allow(paypal_client).to receive(:sync).and_return(paypal_sync_response)

      # Synchronous: it must NOT enqueue a background job.
      expect {
        post sync_paypal_api_v1_bank_connection_path(bc), as: :json
      }.not_to have_enqueued_job(SyncAccountsJob)

      expect(response).to have_http_status(:ok)
      expect(bc.reload.status).to eq("authorized")
      account = bc.accounts.find_by(account_uid: "paypal")
      expect(account.transaction_records.count).to eq(3)
      # The dashboard "PayPal-Guthaben" balance from the /sync response is stored.
      expect(account.balance_amount).to eq(BigDecimal("0.00"))
      expect(account.balance_type).to eq("available")
      expect(account.balance_updated_at).to be_present
      expect(bc.last_login_attempt_at).to be_present
      expect(bc.consecutive_failures).to eq(0)
    end

    it "allows a sync once the ~10-min interval has elapsed but blocks within it" do
      allow(paypal_client).to receive(:sync).and_return(paypal_sync_response)

      # Just outside the 10-min window: allowed.
      bc.update!(last_login_attempt_at: 11.minutes.ago)
      post sync_paypal_api_v1_bank_connection_path(bc), as: :json
      expect(response).to have_http_status(:ok)

      # Inside the 10-min window (and far inside the old 1h/1-day windows): blocked.
      bc.update!(last_login_attempt_at: 5.minutes.ago)
      post sync_paypal_api_v1_bank_connection_path(bc), as: :json
      expect(response).to have_http_status(:too_many_requests)
      expect(response.parsed_body["error"]).to eq("rate_limited")
    end

    it "always scrapes the full 365-day window (passes date_from = 365.days.ago), even with stored history" do
      # Full window every sync — never a high-water-mark window — so PayPal's
      # back-dated / late-settling rows can't fall permanently out of range.
      account = create(:account, bank_connection: bc, account_uid: "paypal")
      create(:transaction_record, account: account, booking_date: Date.new(2026, 5, 1))

      freeze_time do
        expect(paypal_client).to receive(:sync).with(
          hash_including(date_from: 365.days.ago.to_date.iso8601)
        ).and_return(paypal_sync_response)

        post sync_paypal_api_v1_bank_connection_path(bc), as: :json
        expect(response).to have_http_status(:ok)
      end
    end

    it "rejects a second sync within the rate-limit window with 429 rate_limited" do
      allow(paypal_client).to receive(:sync).and_return(paypal_sync_response)
      post sync_paypal_api_v1_bank_connection_path(bc), as: :json
      expect(response).to have_http_status(:ok)

      post sync_paypal_api_v1_bank_connection_path(bc), as: :json
      expect(response).to have_http_status(:too_many_requests)
      expect(response.parsed_body["error"]).to eq("rate_limited")
      # Only one login attempt actually reached the sidecar.
      expect(paypal_client).to have_received(:sync).once
    end

    it "returns 409 push_timeout when the device push is not approved in time" do
      allow(paypal_client).to receive(:sync).and_raise(Paypal::PushTimeout.new("not approved"))

      post sync_paypal_api_v1_bank_connection_path(bc), as: :json

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["error"]).to eq("push_timeout")
      expect(bc.reload.consecutive_failures).to eq(1)
    end

    it "returns 422 captcha_blocked and advances the breaker" do
      allow(paypal_client).to receive(:sync).and_raise(Paypal::CaptchaBlocked.new("security check"))

      post sync_paypal_api_v1_bank_connection_path(bc), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to eq("captcha_blocked")
      expect(bc.reload.consecutive_failures).to eq(1)
    end

    it "trips the circuit breaker to error after N consecutive captcha/push failures" do
      allow(paypal_client).to receive(:sync).and_raise(Paypal::CaptchaBlocked.new("security check"))
      bc.update!(consecutive_failures: 2) # one more failure trips it (N=3)

      post sync_paypal_api_v1_bank_connection_path(bc), as: :json

      expect(bc.reload.consecutive_failures).to eq(3)
      expect(bc.status).to eq("error")
    end

    it "resets the breaker and clears error on a successful sync" do
      bc.update!(consecutive_failures: 2, status: "error", error_message: "prev")
      bc.update!(last_login_attempt_at: nil) # not rate-limited
      allow(paypal_client).to receive(:sync).and_return(paypal_sync_response)

      post sync_paypal_api_v1_bank_connection_path(bc), as: :json

      expect(response).to have_http_status(:ok)
      expect(bc.reload.consecutive_failures).to eq(0)
      expect(bc.status).to eq("authorized")
      expect(bc.error_message).to be_nil
    end

    it "surfaces bad credentials as 422 login_failed and marks the connection error" do
      allow(paypal_client).to receive(:sync).and_raise(Paypal::LoginFailed.new("bad creds"))

      post sync_paypal_api_v1_bank_connection_path(bc), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to eq("login_failed")
      expect(bc.reload.status).to eq("error")
    end

    it "returns 422 when paypal is not configured" do
      credential.destroy!

      post sync_paypal_api_v1_bank_connection_path(bc), as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "atomically claims the rate-limit slot (a pre-stamped recent attempt blocks, no login fires)" do
      # Simulate a slot already claimed within the window (the second of a
      # double-click / two-tab race). The check-and-stamp is atomic, so this
      # request must be rejected WITHOUT calling the sidecar.
      bc.update!(last_login_attempt_at: 1.minute.ago)
      expect(paypal_client).not_to receive(:sync)

      post sync_paypal_api_v1_bank_connection_path(bc), as: :json

      expect(response).to have_http_status(:too_many_requests)
      expect(response.parsed_body["error"]).to eq("rate_limited")
    end

    it "does NOT consume the rate-limit budget when the sidecar is unavailable (no login occurred)" do
      bc.update!(last_login_attempt_at: nil)
      allow(paypal_client).to receive(:sync)
        .and_raise(Paypal::SidecarUnavailableError.new("down", status: 503))

      post sync_paypal_api_v1_bank_connection_path(bc), as: :json

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body["error"]).to eq("scraper_unavailable")
      # The optimistic stamp is rolled back so a mere sidecar restart doesn't lock
      # the user out for ~20h, and the breaker is NOT advanced (no login attempted).
      bc.reload
      expect(bc.last_login_attempt_at).to be_nil
      expect(bc.consecutive_failures).to eq(0)
      expect(bc.status).to eq("authorized")
    end

    it "maps a sidecar invalid_request to a distinct non-transient bad_gateway without consuming budget" do
      bc.update!(last_login_attempt_at: nil)
      allow(paypal_client).to receive(:sync)
        .and_raise(Paypal::InvalidRequestError.new("bad body", status: 422))

      post sync_paypal_api_v1_bank_connection_path(bc), as: :json

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body["error"]).to eq("invalid_request")
      expect(bc.reload.last_login_attempt_at).to be_nil
    end

    it "KEEPS the rate-limit budget on a read timeout (a login likely fired) so the user can't immediately re-burst" do
      # Unlike SidecarUnavailable (no login), a read timeout means the sidecar was
      # already driving the browser — a real PayPal login almost certainly fired.
      # The optimistic stamp must therefore be PRESERVED, not rolled back, so the
      # ~10-min velocity gate still holds.
      bc.update!(last_login_attempt_at: nil)
      allow(paypal_client).to receive(:sync)
        .and_raise(Paypal::SyncTimeoutError.new("timed out"))

      post sync_paypal_api_v1_bank_connection_path(bc), as: :json

      expect(response).to have_http_status(:gateway_timeout)
      expect(response.parsed_body["error"]).to eq("sync_timeout")
      bc.reload
      expect(bc.last_login_attempt_at).to be_present # stamp kept => velocity gate holds
      expect(bc.consecutive_failures).to eq(0)       # transient, not a breaker failure
      expect(bc.status).to eq("authorized")
    end
  end
end
