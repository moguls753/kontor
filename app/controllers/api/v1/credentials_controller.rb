module Api
  module V1
    class CredentialsController < ApplicationController
      def show
        eb = Current.user.enable_banking_credential
        gc = Current.user.go_cardless_credential
        tr = Current.user.trade_republic_credential
        easybank = Current.user.easybank_credential
        llm = Current.user.llm_credential

        render json: {
          enable_banking: eb ? { configured: true, app_id: eb.app_id } : { configured: false },
          gocardless: gc ? { configured: true } : { configured: false },
          trade_republic: tr ? { configured: true, phone_number_masked: tr.phone_number_masked } : { configured: false },
          easybank: easybank ? { configured: true, username_masked: easybank.username_masked } : { configured: false },
          llm: llm ? { configured: true, base_url: llm.base_url, llm_model: llm.llm_model } : { configured: false }
        }
      end

      def create
        case params[:provider]
        when "enable_banking"
          return render json: { error: "Already configured" }, status: :conflict if Current.user.enable_banking_credential
          credential = Current.user.build_enable_banking_credential(eb_params)
        when "gocardless"
          return render json: { error: "Already configured" }, status: :conflict if Current.user.go_cardless_credential
          credential = Current.user.build_go_cardless_credential(gc_params)
        when "llm"
          return render json: { error: "Already configured" }, status: :conflict if Current.user.llm_credential
          credential = Current.user.build_llm_credential(llm_params)
        when "trade_republic"
          return render json: { error: "Already configured" }, status: :conflict if Current.user.trade_republic_credential
          credential = Current.user.build_trade_republic_credential(tr_params)
        when "easybank"
          return render json: { error: "Already configured" }, status: :conflict if Current.user.easybank_credential
          credential = Current.user.build_easybank_credential(easybank_params)
        else
          return render json: { error: "Invalid provider" }, status: :unprocessable_content
        end

        if credential.save
          render json: { provider: params[:provider], configured: true }, status: :created
        else
          render json: { errors: credential.errors.full_messages }, status: :unprocessable_content
        end
      end

      def update
        case params[:provider]
        when "enable_banking"
          credential = Current.user.enable_banking_credential
          return render json: { error: "Not configured" }, status: :not_found unless credential
          credential.assign_attributes(eb_params)
        when "gocardless"
          credential = Current.user.go_cardless_credential
          return render json: { error: "Not configured" }, status: :not_found unless credential
          credential.assign_attributes(gc_params)
        when "llm"
          credential = Current.user.llm_credential
          return render json: { error: "Not configured" }, status: :not_found unless credential
          credential.assign_attributes(llm_params)
        when "trade_republic"
          credential = Current.user.trade_republic_credential
          return render json: { error: "Not configured" }, status: :not_found unless credential
          credential.assign_attributes(tr_params)
        when "easybank"
          credential = Current.user.easybank_credential
          return render json: { error: "Not configured" }, status: :not_found unless credential
          credential.assign_attributes(easybank_params)
        else
          return render json: { error: "Invalid provider" }, status: :unprocessable_content
        end

        if credential.save
          render json: { provider: params[:provider], configured: true }
        else
          render json: { errors: credential.errors.full_messages }, status: :unprocessable_content
        end
      end

      def test
        credential = Current.user.llm_credential
        return render json: { status: "error", message: "LLM not configured" }, status: :unprocessable_content unless credential

        uri = URI("#{credential.base_url.chomp("/")}/chat/completions")
        headers = { "Content-Type" => "application/json" }
        headers["Authorization"] = "Bearer #{credential.api_key}" if credential.api_key.present?

        body = {
          model: credential.llm_model,
          messages: [ { role: "user", content: "Say hello in one word." } ],
          max_tokens: 10
        }

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 10
        http.read_timeout = 10

        response = http.post(uri.request_uri, body.to_json, headers)

        if response.code.to_i.between?(200, 299)
          data = JSON.parse(response.body)
          reply = data.dig("choices", 0, "message", "content") || "OK"
          render json: { status: "ok", message: reply.strip }
        else
          render json: { status: "error", message: "HTTP #{response.code}: #{response.body.truncate(200)}" }
        end
      rescue Net::OpenTimeout, Net::ReadTimeout
        render json: { status: "error", message: "Connection timed out" }
      rescue SocketError, Errno::ECONNREFUSED => e
        render json: { status: "error", message: "Connection failed: #{e.message}" }
      rescue => e
        render json: { status: "error", message: e.message.truncate(200) }
      end

      private

      def eb_params
        params.expect(credentials: [ :app_id, :private_key_pem ])
      end

      def gc_params
        params.expect(credentials: [ :secret_id, :secret_key ])
      end

      def llm_params
        params.expect(credentials: [ :base_url, :api_key, :llm_model ])
      end

      def tr_params
        params.expect(credentials: [ :phone_number, :pin ])
      end

      def easybank_params
        params.expect(credentials: [ :username, :password ])
      end
    end
  end
end
