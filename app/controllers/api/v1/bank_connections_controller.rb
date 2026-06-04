module Api
  module V1
    class BankConnectionsController < ApplicationController
      def index
        connections = Current.user.bank_connections.includes(:accounts).order(created_at: :desc)
        render json: connections.map { |bc| connection_json(bc) }
      end

      def show
        bc = Current.user.bank_connections.includes(:accounts).find(params[:id])
        render json: connection_json(bc)
      end

      def create
        credential = provider_credential(params[:provider])
        return render json: { error: "#{params[:provider]} not configured" }, status: :unprocessable_content unless credential

        # Trade Republic pairs through the sidecar (no OAuth redirect) and uses a
        # synthetic institution_id with a one-per-user guard — handle separately.
        return create_trade_republic(credential) if params[:provider] == "trade_republic"
        # easybank logs in through its own sidecar (no OAuth redirect), same
        # synthetic institution_id / one-per-user pattern.
        return create_easybank(credential) if params[:provider] == "easybank"

        bc = Current.user.bank_connections.build(
          provider: params[:provider],
          institution_id: params[:institution_id],
          institution_name: params[:institution_name],
          country_code: params[:country_code],
          status: "pending"
        )

        unless bc.save
          return render json: { errors: bc.errors.full_messages }, status: :unprocessable_content
        end

        case bc.provider
        when "enable_banking"
          create_enable_banking(bc, credential)
        when "gocardless"
          create_gocardless(bc, credential)
        end
      rescue EnableBanking::ApiError, GoCardless::ApiError => e
        bc&.update!(status: "error", error_message: e.message)
        render json: { error: e.message }, status: :bad_gateway
      end

      def callback
        # `id` is present on the member route (GoCardless); the stable collection
        # route resolves the connection from the `state` the provider echoes back.
        bc = Current.user.bank_connections.find(params[:id] || params[:state])

        if params[:error].present?
          bc.update!(status: "error", error_message: params[:error])
          return redirect_to "/?bank_connection_error=#{bc.id}"
        end

        case bc.provider
        when "enable_banking"
          callback_enable_banking(bc)
        when "gocardless"
          callback_gocardless(bc)
        end
      rescue EnableBanking::ApiError, GoCardless::ApiError => e
        bc.update!(status: "error", error_message: e.message)
        redirect_to "/?bank_connection_error=#{bc.id}"
      end

      def destroy
        bc = Current.user.bank_connections.find(params[:id])

        if bc.enable_banking? && bc.session_id.present?
          credential = Current.user.enable_banking_credential
          if credential
            client = EnableBanking::Client.new(app_id: credential.app_id, private_key_pem: credential.private_key_pem)
            client.delete_session(session_id: bc.session_id) rescue nil
          end
        end

        bc.destroy!
        head :no_content
      end

      def sync
        bc = Current.user.bank_connections.find(params[:id])
        SyncAccountsJob.perform_later(bc.id)
        render json: { queued: true }
      end

      # Re-authorize an existing connection in place (e.g. after a 90-day
      # consent expiry). Reuses the same BankConnection record so its accounts
      # and transaction history are preserved — the provider callback fires on
      # the same :id and find_or_create_by(account_uid) matches existing rows.
      def reconnect
        bc = Current.user.bank_connections.find(params[:id])
        credential = provider_credential(bc.provider)
        return render json: { error: "#{bc.provider} not configured" }, status: :unprocessable_content unless credential

        bc.update!(status: "pending", error_message: nil)

        case bc.provider
        when "enable_banking"
          create_enable_banking(bc, credential)
        when "gocardless"
          create_gocardless(bc, credential)
        when "trade_republic"
          start_tr_pairing(bc, credential)
        when "easybank"
          start_easybank_login(bc, credential)
        end
      rescue EnableBanking::ApiError, GoCardless::ApiError => e
        bc&.update!(status: "error", error_message: e.message)
        render json: { error: e.message }, status: :bad_gateway
      rescue TradeRepublic::Error => e
        render_tr_error(bc, e)
      rescue EasyBank::Error => e
        render_easybank_error(bc, e)
      end

      # Complete a 2FA challenge with the code from the app push (Trade Republic)
      # or the SMS mTAN (easybank). On success ensure the single account exists and
      # kick off the first sync. A wrong/expired code leaves the connection
      # retryable (mirrors the GoCardless callback). Branches on the provider
      # because the two flows talk to different sidecars with different payloads.
      def confirm_2fa
        bc = Current.user.bank_connections.find(params[:id])

        case bc.provider
        when "trade_republic" then confirm_trade_republic(bc)
        when "easybank" then confirm_easybank(bc)
        else
          render json: { error: "#{bc.provider} does not support 2FA confirmation" }, status: :unprocessable_content
        end
      rescue TradeRepublic::Error => e
        render_tr_error(bc, e)
      rescue EasyBank::Error => e
        render_easybank_error(bc, e)
      end

      private

      def confirm_trade_republic(bc)
        credential = Current.user.trade_republic_credential
        return render json: { error: "trade_republic not configured" }, status: :unprocessable_content unless credential

        result = scraper_client("trade_republic").pair_finish(pairing_id: params[:pairing_id], code: params[:code])
        credential.update!(session_blob: result[:session_blob], last_paired_at: Time.current)

        bc.accounts.find_or_create_by!(account_uid: "trade_republic") do |a|
          a.name = bc.institution_name.presence || "Trade Republic"
          a.currency = "EUR"
        end
        bc.update!(status: "authorized", error_message: nil)
        SyncAccountsJob.perform_later(bc.id)

        render json: connection_json(bc.reload)
      end

      # Submit the SMS mTAN to finish the gated backfill. submit_mtan resumes the
      # SAME paused browser context and returns the FULL sync payload (the
      # ~360-day data on a first connect), so we INGEST what we already hold —
      # never enqueue a re-fetch, which would trigger a SECOND mTAN. Record
      # last_paired_at so a later lost sidecar profile can be told apart from a
      # fresh one and we never re-trigger the backfill mTAN unattended.
      def confirm_easybank(bc)
        credential = Current.user.easybank_credential
        return render json: { error: "easybank not configured" }, status: :unprocessable_content unless credential

        result = scraper_client("easybank").submit_mtan(pairing_id: params[:pairing_id], code: params[:code])

        EasyBank::Ingest.call(bc, result)
        bc.update!(status: "authorized", error_message: nil)
        credential.update!(last_paired_at: Time.current)

        render json: connection_json(bc.reload)
      end

      def provider_credential(provider)
        case provider
        when "enable_banking" then Current.user.enable_banking_credential
        when "gocardless" then Current.user.go_cardless_credential
        when "trade_republic" then Current.user.trade_republic_credential
        when "easybank" then Current.user.easybank_credential
        end
      end

      def create_enable_banking(bc, credential)
        client = EnableBanking::Client.new(app_id: credential.app_id, private_key_pem: credential.private_key_pem)
        # Stable callback (no per-connection id) so it matches the single redirect
        # URL registered with Enable Banking; the connection is recovered from the
        # `state` param EB echoes back to the callback.
        callback_url = "#{request.base_url}/api/v1/bank_connections/callback"

        result = client.start_authorization(
          aspsp: { name: bc.institution_id, country: bc.country_code },
          state: bc.id.to_s,
          redirect_url: callback_url,
          valid_until: 180.days.from_now.iso8601
        )

        bc.update!(authorization_id: result[:authorization_id])
        render json: { id: bc.id, redirect_url: result[:url] }, status: :created
      end

      def create_gocardless(bc, credential)
        client = GoCardless::Client.new(credential)
        callback_url = "#{request.base_url}/api/v1/bank_connections/#{bc.id}/callback"

        result = client.create_requisition(institution_id: bc.institution_id, redirect: callback_url)

        bc.update!(requisition_id: result[:id], link: result[:link])
        render json: { id: bc.id, redirect_url: result[:link] }, status: :created
      end

      # Reuse/replace the user's single Trade Republic connection — the
      # [user_id, institution_id] index is NOT unique, so guard explicitly to
      # avoid accumulating orphans. institution_id is synthetic and must be set
      # before save (it is NOT NULL).
      def create_trade_republic(credential)
        bc = Current.user.bank_connections.find_or_initialize_by(
          provider: "trade_republic",
          institution_id: "trade_republic"
        )
        bc.assign_attributes(
          institution_name: "Trade Republic",
          country_code: "DE",
          status: "pending",
          error_message: nil
        )
        bc.save!
        start_tr_pairing(bc, credential)
      rescue TradeRepublic::Error => e
        render_tr_error(bc, e)
      end

      def start_tr_pairing(bc, credential)
        result = scraper_client("trade_republic").pair_start(phone_number: credential.phone_number, pin: credential.pin)
        render json: {
          id: bc.id,
          pairing_id: result[:pairing_id],
          countdown_seconds: result[:countdown_seconds],
          channel: result[:channel]
        }, status: :created
      end

      # Map a TradeRepublic::Error to a status the frontend can act on.
      def render_tr_error(bc, error)
        case error
        when TradeRepublic::PairingExpiredError
          bc&.update!(status: "error", error_message: error.message)
          render json: { error: "pairing_expired", message: error.message }, status: :gone
        when TradeRepublic::PairingFailedError
          # Wrong/expired code or PIN — leave the connection retryable.
          render json: { error: "pairing_failed", message: error.message }, status: :unprocessable_content
        when TradeRepublic::SessionExpiredError
          bc&.update!(status: "expired", error_message: error.message)
          render json: { error: "session_expired", message: error.message }, status: :conflict
        else # ApiError, SidecarUnavailableError
          bc&.update!(status: "error", error_message: error.message)
          render json: { error: "scraper_unavailable", message: error.message }, status: :bad_gateway
        end
      end

      # Reuse/replace the user's single easybank connection — the
      # [user_id, institution_id] index is NOT unique, so guard explicitly to
      # avoid accumulating orphans. institution_id is synthetic and must be set
      # before save (it is NOT NULL). Mirrors create_trade_republic.
      def create_easybank(credential)
        bc = Current.user.bank_connections.find_or_initialize_by(
          provider: "easybank",
          institution_id: "easybank"
        )
        bc.assign_attributes(
          institution_name: "easybank Kreditkarte",
          country_code: "DE",
          status: "pending",
          error_message: nil
        )
        bc.save!
        start_easybank_login(bc, credential)
      rescue EasyBank::Error => e
        render_easybank_error(bc, e)
      end

      # Connect via the sidecar's /sync. The FIRST connect (no transactions yet)
      # requests the one-time ~360-day backfill, which the bank gates behind an
      # SMS mTAN — the sidecar raises MtanRequired and we hand the challenge to
      # the frontend, which collects the code and posts it to confirm_2fa (where
      # the paused browser context resumes and returns the deep payload). Every
      # other connect/reconnect uses the routine 30-day range; a fully
      # device-paired profile then comes straight back with the payload (no
      # mTAN) and we ingest + authorize immediately. A fresh-device 30-day
      # connect can still raise MtanRequired, which is handled the same way.
      def start_easybank_login(bc, credential)
        days = easybank_first_connect?(bc) ? EasyBank::ScraperClient::LONG_BACKFILL_DAYS : EasyBank::ScraperClient::SHORT_BACKFILL_DAYS
        result = scraper_client("easybank").sync(username: credential.username, password: credential.password, backfill_days: days)

        # No mTAN gate: ingest the payload we already hold (never enqueue a
        # re-fetch — a 360-day re-fetch would trigger a SECOND mTAN).
        EasyBank::Ingest.call(bc, result)
        bc.update!(status: "authorized", error_message: nil)
        credential.update!(last_paired_at: Time.current)
        render json: connection_json(bc.reload)
      rescue EasyBank::MtanRequired => e
        render json: {
          id: bc.id,
          mtan_required: true,
          pairing_id: e.pairing_id,
          masked_phone: e.masked_phone,
          reference: e.reference,
          expires_in: e.expires_in
        }, status: :created
      end

      # The one-time deep backfill runs only on the first connect — when this
      # connection has no transactions yet (no account at all, or an account
      # with no transaction_records). Every later connect/reconnect already has
      # history and uses the routine 30-day range.
      def easybank_first_connect?(bc)
        account = bc.accounts.find_by(account_uid: "easybank")
        account.nil? || account.transaction_records.none?
      end

      # Map an EasyBank::Error to a status the frontend can act on. Mirrors
      # render_tr_error. (MtanRequired never reaches here — it is rendered inline
      # by start_easybank_login as a 201 challenge, not surfaced as an error.)
      def render_easybank_error(bc, error)
        case error
        when EasyBank::MtanFailed
          # Wrong/expired SMS code — leave the connection retryable.
          render json: { error: "mtan_failed", message: error.message }, status: :unprocessable_content
        when EasyBank::LoginFailed
          # Bad username/password — the stored credential must be corrected.
          bc&.update!(status: "error", error_message: error.message)
          render json: { error: "login_failed", message: error.message }, status: :unprocessable_content
        when EasyBank::SessionExpiredError
          bc&.update!(status: "expired", error_message: error.message)
          render json: { error: "session_expired", message: error.message }, status: :conflict
        else # ApiError, SidecarUnavailableError
          bc&.update!(status: "error", error_message: error.message)
          render json: { error: "scraper_unavailable", message: error.message }, status: :bad_gateway
        end
      end

      # Provider-aware: each scraped provider has its own network-isolated sidecar.
      def scraper_client(provider)
        @scraper_clients ||= {}
        @scraper_clients[provider] ||= case provider
        when "trade_republic" then TradeRepublic::ScraperClient.new
        when "easybank" then EasyBank::ScraperClient.new
        end
      end

      def callback_enable_banking(bc)
        credential = Current.user.enable_banking_credential
        client = EnableBanking::Client.new(app_id: credential.app_id, private_key_pem: credential.private_key_pem)

        session_data = client.create_session(code: params[:code])

        bc.update!(
          session_id: session_data[:session_id],
          status: "authorized",
          valid_until: DateTime.parse(session_data[:access][:valid_until])
        )

        session_data[:accounts].each do |acct|
          bc.accounts.find_or_create_by!(account_uid: acct[:uid]) do |a|
            a.identification_hash = acct[:identification_hash]
            a.iban = acct[:iban]
            a.name = bc.institution_name
          end
        end

        SyncAccountsJob.perform_later(bc.id)
        redirect_to "/?bank_connection_success=#{bc.id}"
      end

      def callback_gocardless(bc)
        credential = Current.user.go_cardless_credential
        client = GoCardless::Client.new(credential)

        requisition = client.get_requisition(requisition_id: bc.requisition_id)
        account_ids = requisition[:accounts] || []

        # A completed authorization links accounts. If there are none (user
        # abandoned the flow or failed bank auth), don't mark it authorized —
        # leave it in a retryable state with a clear message.
        if account_ids.empty?
          bc.update!(status: "expired", error_message: "Bank authorization was not completed. Reconnect to try again.")
          return redirect_to "/?bank_connection_error=#{bc.id}"
        end

        bc.update!(status: "authorized", error_message: nil)

        account_ids.each do |account_id|
          bc.accounts.find_or_create_by!(account_uid: account_id) do |a|
            a.name = bc.institution_name
          end
        end

        SyncAccountsJob.perform_later(bc.id)
        redirect_to "/?bank_connection_success=#{bc.id}"
      end

      def connection_json(bc)
        {
          id: bc.id,
          provider: bc.provider,
          institution_id: bc.institution_id,
          institution_name: bc.institution_name,
          country_code: bc.country_code,
          status: bc.status,
          valid_until: bc.valid_until,
          last_synced_at: bc.last_synced_at,
          error_message: bc.error_message,
          accounts: bc.accounts.map { |a|
            { id: a.id, iban: a.iban, name: a.display_name, currency: a.currency, balance_amount: a.balance_amount, last_synced_at: a.last_synced_at }
          }
        }
      end
    end
  end
end
