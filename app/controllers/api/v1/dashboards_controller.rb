module Api
  module V1
    class DashboardsController < ApplicationController
      def show
        accounts = Current.user.accounts
        transactions = Current.user.transaction_records.in_period(Date.current.beginning_of_month, Date.current)

        total_balance = accounts.sum(:balance_amount)
        income = transactions.credits.sum(:amount)
        expenses = transactions.debits.sum(:amount)
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
          recent_transactions: recent_transactions
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
            currency: account.currency
          }
        end
      end

      def recent_transactions
        Current.user.transaction_records
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
