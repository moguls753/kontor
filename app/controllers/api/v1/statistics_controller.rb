module Api
  module V1
    # Spending/income analytics for the Statistics page. Every figure derives from
    # the SAME scoped, internal-transfer-excluded universe as the dashboard
    # (ScopedAccounts#in_scope), so the numbers reconcile (plan §1.1, invariant I1).
    class StatisticsController < ApplicationController
      include ScopedAccounts

      # Savings/transfer-flavoured categories, matched by name against BOTH locale
      # default sets (User::DEFAULT_CATEGORIES). The category card no longer singles
      # them out (D-A4: one ranked list — they're plain categories and `in_scope`
      # already nets in-scope transfers per lens). This constant survives ONLY where
      # the Fixkosten logic must exclude pure savings — `fixed_scope` (KPI Fixkosten/Mt
      # + the Fix-vs-variabel chart) and the forecast's `expected_monthly_fixed`:
      # "Sparen" is not a fixed cost (plan §1.3 / §2.1).
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
        top         = cats[:items].first

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
            top_category: top && { name: top[:name], amount: top[:amount] }
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
          categories: cats,
          forecast: forecast(ids, transfer_cat_ids)
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

      # One ranked list of ALL in-scope debit categories (incl. Sparen/Überweisungen
      # as plain categories, and uncategorized debits as a null-named item), sorted by
      # magnitude desc. `total` == |expenses|; every category shown is already a real
      # outflow in the current scope (in_scope nets in-scope transfers per lens), so
      # Σitems == total == |expenses| reconciles trivially (D-A4, plan §1.3).
      def category_items(window)
        amount_by_cat = window.debits.group(:category_id).sum(:amount)
        count_by_cat  = window.debits.group(:category_id).count
        names = Current.user.categories.where(id: amount_by_cat.keys.compact).pluck(:id, :name).to_h

        items = amount_by_cat.map do |cat_id, amount|
          { id: cat_id, name: cat_id && names[cat_id], amount: amount.to_d, count: count_by_cat[cat_id] || 0 }
        end

        total = items.sum(0.to_d) { |i| i[:amount] }
        denom = total.abs
        items.each { |i| i[:share] = denom.zero? ? 0.0 : (i[:amount].abs / denom * 100).round(1).to_f }
        # Largest spend first (amounts are negative → sort ascending).
        items.sort_by! { |i| i[:amount] }

        { items: items, total: total }
      end

      # Forward "typischer Monat" projection — window-INDEPENDENT ("ab heute") but
      # scope-aware (plan §2.1–§2.3). All money serialized as dashboard-style
      # BigDecimal strings (.to_d), so an empty scope renders "0.0", not Integer 0.
      def forecast(ids, transfer_cat_ids)
        # Active series with ≥1 in-scope member (shared A6 filter). flow_bucket only
        # reads each member's transfer_group_id + transfer_counterpart_account_id FK
        # (never the association object), so preloading the members alone is N+1-free.
        scope_ids = params[:scope] == "privat" ? ids : nil
        series = Current.user.recurring_series.active
                        .merge(RecurringSeries.with_member_in(ids))
                        .includes(:transaction_records)
                        .to_a
        buckets = series.to_h { |s| [ s, s.flow_bucket(members: s.transaction_records.to_a, scope_ids: scope_ids) ] }

        income = 0.to_d
        fixed  = 0.to_d
        series.each do |s|
          eq = monthly_equiv(s)
          next if eq.nil?

          case buckets[s]
          when "income"
            income += eq
          when "expense"
            # SAME inclusion rule as fixed_scope: exclude pure savings/transfer cats.
            fixed -= eq unless s.category_id && transfer_cat_ids.include?(s.category_id)
          end
        end

        {
          expected_monthly_income: income,
          expected_monthly_fixed: fixed,
          avg_monthly_variable: avg_monthly_variable(ids, transfer_cat_ids),
          current_balance: Current.user.accounts.where(id: ids).sum(:balance_amount).to_d,
          upcoming: upcoming_payments(series, buckets)
        }.tap { |f| f[:upcoming_total] = f[:upcoming].sum(0.to_d) { |u| u[:amount] } }
      end

      # |expected_amount| normalised to a 30-day month. cd = explicit cadence_days,
      # else the cadence default; skip (nil) if cd nil/≤0 (incl. irregular) — no
      # guess-30. EUR-only in v1 (skip non-EUR series).
      def monthly_equiv(s)
        return nil unless s.currency == "EUR"
        return nil if s.expected_amount.nil?

        cd = (s.cadence_days.presence || RecurringDetector::CADENCE_DAYS[s.cadence])
        return nil if cd.nil? || cd <= 0

        s.expected_amount.abs * 30.0 / cd
      end

      # Avg over the last 3 FULL calendar months (current partial month excluded) of
      # in-scope debits that are NOT a fixed cost (recurring_series_id IS NULL OR
      # category ∈ transfer cats), signed negative (.to_d). This is the chart's
      # "variabel" (discretionary + savings); carries savings outflows under Privat.
      #
      # Divisor = months of HISTORY in the window — distinct YYYY-MM buckets that had ANY
      # in-scope debit — capped 1..3 (review S1). NOT months that happened to have variable
      # spend: a full month with only fixed costs is a real €0-variable month that pulls the
      # average DOWN; counting it on the filtered set would overstate the run-rate. Only
      # months with NO history are excluded (short-history guard — a brand-new account with
      # one full month of €600 variable reports €600/mo (÷1), not €200/mo (÷3)).
      def avg_monthly_variable(ids, transfer_cat_ids)
        from = Date.current.beginning_of_month.prev_month(3)
        to   = Date.current.beginning_of_month - 1.day
        debits = in_scope(Current.user.transaction_records.in_period(from, to), ids).debits
        months_with_data = debits.distinct.count(MONTH)
        divisor = [ [ 3, months_with_data ].min, 1 ].max
        variable = if transfer_cat_ids.any?
          debits.where("recurring_series_id IS NULL OR category_id IN (?)", transfer_cat_ids)
        else
          debits.where(recurring_series_id: nil)
        end
        (variable.sum(:amount).to_d / divisor)
      end

      # Anstehende Zahlungen: active in-scope series whose next_expected_on falls in
      # [today, today+30 days], scope-aware flow_bucket != "transfer", ONE row per
      # series, sorted by date asc. `series`/`buckets` are reused from #forecast.
      def upcoming_payments(series, buckets)
        window = Date.current..(Date.current + 30.days)
        series.select { |s| buckets[s] != "transfer" && s.currency == "EUR" && s.next_expected_on && window.cover?(s.next_expected_on) }
              .sort_by(&:next_expected_on)
              .map do |s|
                {
                  name: s.canonical_name,
                  date: s.next_expected_on,
                  amount: s.expected_amount,
                  direction: s.direction
                }
              end
      end
    end
  end
end
