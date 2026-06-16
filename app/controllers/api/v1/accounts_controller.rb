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
        attrs = account_params.to_h.symbolize_keys
        # If the user set the role or shared flag by hand, lock it so the
        # AccountRoleInferrer (§2a) never overrides their choice.
        classification_changed = attrs.key?(:role) || attrs.key?(:shared)
        attrs[:role_locked] = true if classification_changed
        account.update!(attrs)
        # role/shared feed the Gemeinsam/Privat scope filter (and historically transfer
        # classification), so re-run the post-sync pipeline when they change (debounced
        # per user). A pure rename doesn't affect classification → skip it.
        ProcessAccountDataJob.perform_later(Current.user.id) if classification_changed
        render json: account_json(account)
      end

      private

      def account_params
        params.permit(:name, :role, :shared)
      end

      def account_json(account)
        {
          id: account.id,
          account_uid: account.account_uid,
          iban: account.iban,
          name: account.display_name,
          role: account.role,
          shared: account.shared,
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
