module Api
  module V1
    # Spending/income analytics for the Statistics page. Every figure derives from
    # the SAME scoped, internal-transfer-excluded universe as the dashboard
    # (ScopedAccounts#in_scope), so the numbers reconcile (plan §1.1, invariant I1).
    class StatisticsController < ApplicationController
      include ScopedAccounts

      # Categories that represent internal money movement, not spending. Matched by
      # name against BOTH locale default sets (User::DEFAULT_CATEGORIES). They are
      # NOT hidden — they're returned as a separate `transfers` group the UI renders
      # muted, so Σspending + Σtransfers always == |expenses| (plan §1.3 / review S3).
      TRANSFER_CATEGORY_NAMES = ["Überweisungen", "Transfers", "Sparen", "Savings"].freeze

      # SQLite-only month bucket (the app is SQLite-only per CLAUDE.md). Used only as
      # a GROUP BY expression — the summed column stays a typed decimal, so grouped
      # `.sum(:amount)` returns BigDecimal (sidesteps the raw-Arel Float trap, S2).
      MONTH = Arel.sql("strftime('%Y-%m', booking_date)")

      def show
        ids = scoped_account_ids
        to   = parse_date(params[:to], Date.current)
        from = parse_date(params[:from], to.beginning_of_month - 5.months)
        from = to if from > to
        # SF1: bound the window so a hand-crafted `from` can't drive build_series
        # through thousands of months (the UI only ever requests ≤12-month presets;
        # 36 months is generous headroom). The earliest-tx clamp below narrows further.
        from = [from, to.advance(months: -36)].max

        window = in_scope(Current.user.transaction_records.in_period(from, to), ids)

        # I4: clamp the display start to the earliest tx actually in the window, so
        # accounts with shorter history don't render empty leading months.
        earliest = window.minimum(:booking_date)
        clamped_from = earliest && earliest > from ? earliest : from
        months = month_span(clamped_from, to)

        income_by_month  = window.credits.group(MONTH).sum(:amount)
        expense_by_month = window.debits.group(MONTH).sum(:amount)
        # "Fixed" = recurring-linked REAL spending. Exclude only the transfer/savings
        # categories (Sparen/Überweisungen), NOT all matched transfers: a recurring
        # cost-share paid into a joint account (rent, utilities) IS a fixed cost from the
        # Privat view and must count — it survives `in_scope` there as a real outflow.
        transfer_cat_ids = Current.user.categories.where(name: TRANSFER_CATEGORY_NAMES).pluck(:id)
        fixed_scope      = window.debits.where.not(recurring_series_id: nil)
        fixed_scope      = fixed_scope.where("category_id IS NULL OR category_id NOT IN (?)", transfer_cat_ids) if transfer_cat_ids.any?
        fixed_by_month   = fixed_scope.group(MONTH).sum(:amount)

        income      = window.credits.sum(:amount).to_d
        expenses    = window.debits.sum(:amount).to_d
        total_fixed = fixed_scope.sum(:amount).to_d
        cats        = category_items(window)
        top         = cats[:spending].first
        # Earliest in-scope tx overall (not just in-window) — used to suppress the
        # prior-period delta when the previous window predates the user's data.
        earliest_overall = in_scope(Current.user.transaction_records, ids).minimum(:booking_date)
        prev        = previous_window_kpis(ids, clamped_from, months, earliest_overall)

        render json: {
          range: { from: clamped_from, to: to, months: months, clamped: clamped_from != from },
          transaction_count: window.count,
          kpis: {
            income: income,
            expenses: expenses,
            net: income + expenses,
            savings_rate: savings_rate(income + expenses, income),
            avg_monthly_expenses: (expenses / months).round(2),
            fixed_monthly: (total_fixed / months).round(2),
            recurring_payment_count: fixed_scope.distinct.count(:recurring_series_id),
            top_category: top && { name: top[:name], amount: top[:amount] },
            savings_rate_prev: prev[:savings_rate],
            avg_monthly_expenses_prev: prev[:avg_monthly_expenses]
          },
          cashflow: build_series(clamped_from, to) { |m|
            inc = (income_by_month[m] || 0).to_d
            exp = (expense_by_month[m] || 0).to_d
            { month: m, income: inc, expenses: exp, net: inc + exp }
          },
          fixed_variable: build_series(clamped_from, to) { |m|
            total = (expense_by_month[m] || 0).to_d
            fixed = (fixed_by_month[m] || 0).to_d
            { month: m, fixed: fixed, variable: total - fixed }
          },
          categories: cats
        }
      end

      private

      def parse_date(value, default)
        value.present? ? Date.iso8601(value.to_s) : default
      rescue ArgumentError, TypeError
        default
      end

      # Inclusive count of calendar months in [from, to], min 1 (review S4 — the
      # denominator for avg_monthly_expenses / fixed_monthly).
      def month_span(from, to)
        return 1 if from > to

        (to.year * 12 + to.month) - (from.year * 12 + from.month) + 1
      end

      # Continuous, zero-filled month list so the chart axis has no gaps.
      def build_series(from, to)
        keys = []
        cursor = from.beginning_of_month
        stop = to.beginning_of_month
        while cursor <= stop
          keys << cursor.strftime("%Y-%m")
          cursor = cursor.next_month
        end
        keys.map { |m| yield m }
      end

      def savings_rate(net, income)
        return nil unless income.positive?

        (net / income * 100).round(1).to_f
      end

      # All debit categories, split into a `spending` group and a muted `transfers`
      # group (Sparen/Überweisungen). Uncategorized debits (category_id NULL) are
      # spending with a null name. total_spent = Σspending; the two groups together
      # always sum to |expenses| (the reconciliation the UI relies on, S3).
      def category_items(window)
        amount_by_cat = window.debits.group(:category_id).sum(:amount)
        count_by_cat  = window.debits.group(:category_id).count
        names = Current.user.categories.where(id: amount_by_cat.keys.compact).pluck(:id, :name).to_h

        spending = []
        transfers = []
        amount_by_cat.each do |cat_id, amount|
          name = cat_id && names[cat_id]
          item = { id: cat_id, name: name, amount: amount.to_d, count: count_by_cat[cat_id] || 0 }
          if name && TRANSFER_CATEGORY_NAMES.include?(name)
            transfers << item.merge(share: nil)
          else
            spending << item
          end
        end

        total_spent = spending.sum(0.to_d) { |i| i[:amount] }
        denom = total_spent.abs
        spending.each { |i| i[:share] = denom.zero? ? 0.0 : (i[:amount].abs / denom * 100).round(1).to_f }

        # Largest spend first (amounts are negative → sort ascending).
        spending.sort_by! { |i| i[:amount] }
        transfers.sort_by! { |i| i[:amount] }

        { spending: spending, transfers: transfers, total_spent: total_spent }
      end

      # Same-length window immediately before the current one, for the KPI deltas.
      def previous_window_kpis(ids, clamped_from, months, earliest_overall)
        prev_from = clamped_from.advance(months: -months)
        # Suppress the comparison when the prior window predates the user's data — a
        # near-empty prior window otherwise yields a meaningless +1000 % delta.
        return { savings_rate: nil, avg_monthly_expenses: nil } if earliest_overall.nil? || prev_from < earliest_overall

        prev_to = clamped_from - 1
        prev = in_scope(Current.user.transaction_records.in_period(prev_from, prev_to), ids)
        income = prev.credits.sum(:amount).to_d
        expenses = prev.debits.sum(:amount).to_d
        { savings_rate: savings_rate(income + expenses, income), avg_monthly_expenses: (expenses / months).round(2) }
      end
    end
  end
end
