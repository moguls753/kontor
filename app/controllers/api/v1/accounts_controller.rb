module Api
  module V1
    class AccountsController < ApplicationController
      def index
        accounts = Current.user.accounts.includes(:bank_connection).order(:id)
        render json: accounts.map { |a| account_json(a) }
      end

      def show
        account = Current.user.accounts.includes(:bank_connection).find(params[:id])
        render json: account_json(account)
      end

      def update
        account = Current.user.accounts.find(params[:id])
        account.update!(name: params[:name])
        render json: account_json(account)
      end

      private

      def account_json(account)
        {
          id: account.id,
          account_uid: account.account_uid,
          iban: account.iban,
          name: account.display_name,
          currency: account.currency,
          balance_amount: account.balance_amount,
          balance_type: account.balance_type,
          balance_updated_at: account.balance_updated_at,
          last_synced_at: account.last_synced_at,
          bank_connection: {
            id: account.bank_connection.id,
            provider: account.bank_connection.provider,
            institution_name: account.bank_connection.institution_name
          }
        }
      end
    end
  end
end
