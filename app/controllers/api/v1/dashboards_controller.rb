module Api
  module V1
    class DashboardsController < ApplicationController
      include ScopedAccounts

      def show
        ids = scoped_account_ids
        accounts = Current.user.accounts.where(id: ids)
        period = Current.user.transaction_records.in_period(Date.current.beginning_of_month, Date.current)
        # §4a: drop matched internal transfers whose counterpart is also in scope.
        transactions = in_scope(period, ids)

        total_balance = accounts.sum(:balance_amount)
        # Coerce to BigDecimal: a `.none` relation (empty scope) sums to Integer 0,
        # which would break the decimal serialization contract ("0.0").
        income = transactions.credits.sum(:amount).to_d
        expenses = transactions.debits.sum(:amount).to_d
        net = income + expenses
        previous_balance = total_balance - net
        balance_change_percent = if previous_balance.zero?
                                   nil
        else
                                   (net / previous_balance.abs * 100).round(1).to_f
        end

        render json: {
          total_balance: total_balance,
          balance_change: net,
          balance_change_percent: balance_change_percent,
          income: income,
          expenses: expenses,
          transaction_count: transactions.count,
          uncategorized_count: transactions.uncategorized.count,
          accounts: accounts_summary(accounts),
          recent_transactions: recent_transactions(ids)
        }
      end

      private

      def accounts_summary(accounts)
        accounts.map do |account|
          {
            id: account.id,
            name: account.display_name,
            iban: account.iban,
            balance_amount: account.balance_amount,
            currency: account.currency,
            last_synced_at: account.last_synced_at
          }
        end
      end

      def recent_transactions(ids)
        # §4c: recent feed is scoped by account ONLY — it must NOT apply the
        # internal-transfer exclusion, or money moved to an in-scope account
        # (e.g. savings) would vanish from the most-recent activity list.
        scope = ids.empty? ? Current.user.transaction_records.none : Current.user.transaction_records.where(account_id: ids)
        scope
          .includes(:account, :category)
          .order(booking_date: :desc, id: :desc)
          .limit(5)
          .map do |tx|
            {
              id: tx.id,
              amount: tx.amount,
              currency: tx.currency,
              booking_date: tx.booking_date,
              remittance: tx.remittance,
              creditor_name: tx.creditor_name,
              debtor_name: tx.debtor_name,
              account_name: tx.account.display_name,
              category: tx.category ? { id: tx.category.id, name: tx.category.name } : nil
            }
          end
      end
    end
  end
end
