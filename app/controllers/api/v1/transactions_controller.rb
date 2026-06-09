module Api
  module V1
    class TransactionsController < ApplicationController
      include ScopedAccounts

      def index
        # §4b: restrict to the in-scope accounts and apply the §4a internal-transfer
        # exclusion (matched transfer whose counterpart is also in scope ⇒ net zero ⇒
        # hidden; counterpart out of scope ⇒ real flow ⇒ stays).
        scope = in_scope(Current.user.transaction_records.includes(:account, :category))

        scope = scope.where(account_id: params[:account_id]) if params[:account_id].present?
        scope = scope.where(category_id: params[:category_id]) if params[:category_id].present?
        scope = scope.where(booking_date: params[:from]..) if params[:from].present?
        scope = scope.where(booking_date: ..params[:to]) if params[:to].present?
        scope = scope.uncategorized if params[:uncategorized] == "true"
        scope = scope.where("remittance LIKE ? OR creditor_name LIKE ? OR debtor_name LIKE ?",
          "%#{params[:search]}%", "%#{params[:search]}%", "%#{params[:search]}%") if params[:search].present?

        scope = scope.order(booking_date: :desc, id: :desc)

        page = [ params.fetch(:page, 1).to_i, 1 ].max
        per = [ params.fetch(:per, 50).to_i.clamp(1, 100) ]
        per = per.first
        total = scope.count

        records = scope.offset((page - 1) * per).limit(per)

        render json: {
          transactions: records.map { |tx| transaction_json(tx) },
          meta: { page: page, per: per, total: total, total_pages: (total.to_f / per).ceil }
        }
      end

      def categorize
        return render json: { error: "LLM not configured" }, status: :unprocessable_content unless Current.user.llm_credential

        results = CategorizeTransactionsJob.perform_now(Current.user.id)
        render json: results
      end

      private

      def transaction_json(tx)
        {
          id: tx.id,
          transaction_id: tx.transaction_id,
          amount: tx.amount,
          currency: tx.currency,
          booking_date: tx.booking_date,
          value_date: tx.value_date,
          status: tx.status,
          remittance: tx.remittance,
          creditor_name: tx.creditor_name,
          creditor_iban: tx.creditor_iban,
          debtor_name: tx.debtor_name,
          debtor_iban: tx.debtor_iban,
          bank_transaction_code: tx.bank_transaction_code,
          category: tx.category ? { id: tx.category.id, name: tx.category.name } : nil,
          account_id: tx.account_id,
          account_name: tx.account.name
        }
      end
    end
  end
end
