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
        bc = Current.user.bank_connections.find(params[:id])

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

      private

      def provider_credential(provider)
        case provider
        when "enable_banking" then Current.user.enable_banking_credential
        when "gocardless" then Current.user.go_cardless_credential
        end
      end

      def create_enable_banking(bc, credential)
        client = EnableBanking::Client.new(app_id: credential.app_id, private_key_pem: credential.private_key_pem)
        callback_url = "#{request.base_url}/api/v1/bank_connections/#{bc.id}/callback"

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
        bc.update!(status: "authorized")

        (requisition[:accounts] || []).each do |account_id|
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
            { id: a.id, iban: a.iban, name: a.display_name, currency: a.currency, balance_amount: a.balance_amount }
          }
        }
      end
    end
  end
end
