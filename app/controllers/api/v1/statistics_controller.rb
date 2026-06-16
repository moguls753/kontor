module Api
  module V1
    # Spending/income analytics for the Statistics page. Every figure derives from
    # the SAME scoped, internal-transfer-excluded universe as the dashboard
    # (ScopedAccounts#in_scope), so the numbers reconcile (plan §1.1, invariant I1).
    class StatisticsController < ApplicationController
      include ScopedAccounts
      include TransactionSerialization

      # Savings/transfer-flavoured categories, matched by name against BOTH locale
      # default sets (User::DEFAULT_CATEGORIES). The category card no longer singles
      # them out (D-A4: one ranked list — they're plain categories and `in_scope`
      # already nets in-scope transfers per lens). This constant survives ONLY in
      # `fixed_scope` — the Fixkosten/Mt KPI + the Fix-vs-variabel chart — which must
      # exclude pure savings ("Sparen" is not a fixed COST). NB: the forecast is CASHFLOW,
      # not Fixkosten — it does NOT use this exclusion; a recurring Sparen outflow counts
      # there as a recurring expense (plan §1.3, redesign 2026-06-10).
      TRANSFER_CATEGORY_NAMES = ["Überweisungen", "Transfers", "Sparen", "Savings"].freeze

      # SQLite-only month bucket (the app is SQLite-only per CLAUDE.md). Used only as
      # a GROUP BY expression — the summed column stays a typed decimal, so grouped
      # `.sum(:amount)` returns BigDecimal (sidesteps the raw-Arel Float trap, S2).
      MONTH = Arel.sql("strftime('%Y-%m', booking_date)")

      # Lookback for the forecast's VARIABLE-flow average (full months; current partial
      # month excluded). Long enough to amortise lumps (vacations, annual bills) and let a
      # one-off and its refund both land in the window. ⚠️ The divisor is months-WITH-DATA,
      # NEVER this flat number (see variable_averages).
      FORECAST_WINDOW_MONTHS = 6

      # Server-side cap for the per-category Empfänger list (plan §2.2): the UI shows the
      # first 8 and reveals the rest with "+N weitere". Capping breaks strict Σitems ==
      # total, so the response returns the UN-capped per-category `total` for the drill
      # footer (invariant CM1).
      TOP_MERCHANTS = 12

      def show
        w = stats_window(params)
        ids = w[:ids]
        from = w[:from]
        to = w[:to]
        window = w[:window]
        clamped_from = w[:clamped_from]
        months = w[:months]

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
        month_keys  = build_series(clamped_from, to) { |m| m }   # the chart's "%Y-%m" order (§3b.3)

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
          # Verlauf Ø-reference (§3b) — the trailing Ø + last-completed-month delta the
          # Verlauf chart draws, computed from the display-window per-month series #show
          # already built (income_by_month/expense_by_month + month_keys). No extra query.
          vs_average: vs_average(month_keys, income_by_month, expense_by_month),
          forecast: forecast(ids)
        }
      end

      # Drill-down for the forecast's "Variable Einnahmen/Ausgaben · Ø N Mt." ledger
      # rows: the individual non-recurring transactions that make up the average,
      # over the SAME clamped window/scope as #forecast (variable_window). Read-only.
      # `kind=income` ⇒ non-recurring credits; anything else ⇒ non-recurring debits.
      def variable_transactions
        ids  = scoped_account_ids
        kind = params[:kind] == "income" ? "income" : "expenses"
        w    = variable_window(ids)
        rel  = kind == "income" ? w[:nonrec].credits : w[:nonrec].debits
        rows = rel.includes(:account, :category).order(booking_date: :desc, id: :desc)

        divisor = [ w[:months], 1 ].max
        total   = rel.sum(:amount).to_d
        render json: {
          kind: kind,
          range: { from: w[:from], to: w[:to] },
          months: w[:months],
          total: total,
          average: (total / divisor),
          transactions: rows.map { |tx| transaction_json(tx) }
        }
      end

      # Leaf of the Ausgaben drill: the individual transactions behind ONE category bar
      # (invariant CI1) — and, when `creditor` is present, narrowed to ONE Empfänger
      # within that category (CM2), so it reconciles to that payee's row in the level-1
      # list (#merchants, §2.2). Same clamped display window/scope as #show's
      # category_items (so Σ tx.amount == the bar's amount). Read-only.
      #
      # NB §2.1/n1: this deliberately does NOT consume stats_window — it must use the
      # RAW passed-in `from` WITHOUT the I4 earliest-tx re-clamp, because the frontend
      # already sends the clamped data.range.from/to (re-clamping could narrow a
      # legitimately re-sent window). So it keeps its own short window block (SF1 floor
      # + `from = to if from > to` only).
      def category_transactions
        ids  = scoped_account_ids
        to   = parse_date(params[:to], Date.current)
        from = parse_date(params[:from], to.beginning_of_month - 5.months)
        from = to if from > to
        from = [ from, to.advance(months: -36) ].max          # SF1 36-month floor

        window        = in_scope(Current.user.transaction_records.in_period(from, to), ids)
        uncategorized = params[:uncategorized] == "1"
        category_id   = uncategorized ? nil : params[:category_id].presence

        rel = window.debits.where(category_id: category_id)

        # Optional payee leaf (CM2). When `creditor` is present we are drilling INTO the
        # per-category Empfänger ranking (§2.2), which (a) drops person-to-person transfers
        # and (b) groups by the NORMALISED creditor_name — so the leaf MUST mirror both, or
        # Σ(leaf) ≠ the payee row. `creditor=""`/blank ⇒ that category's null/no-creditor
        # bucket. EAGER-LOAD BEFORE the Ruby filter (review m1): `.select { … }` materialises
        # an Array, so a later `.includes` would be a no-op and transaction_json would N+1 on
        # tx.account/tx.category (violating §1.2) — include here, while `rel` is a relation.
        if params.key?(:creditor)
          want = normalize_merchant(params[:creditor])         # nil for the "" / blank bucket
          rel  = rel.where(transfer_group_id: nil)             # mirror §2.2's person-transfer drop
                    .includes(:account, :category)
                    .order(booking_date: :desc, id: :desc)
                    .select { |tx| normalize_merchant(tx.creditor_name) == want }
        end

        # When `creditor` filtered, `rel` is already an eager-loaded Array (account+category
        # preloaded above) → the ternary falls through to it; the no-`creditor` path is still a
        # relation and gets `.includes` here. `total`/`count` below handle both via Enumerable.
        rows = (rel.respond_to?(:includes) ? rel.includes(:account, :category) : rel)
                 .sort_by { |tx| [ tx.booking_date, tx.id ] }.reverse   # DESC for groupByMonth

        category_name =
          (uncategorized || category_id.nil?) ? nil
            : Current.user.categories.where(id: category_id).pick(:name)

        render json: {
          category: { id: category_id&.to_i, name: category_name },
          range: { from: from, to: to },
          total: rows.sum(0.to_d) { |tx| tx.amount.to_d },
          count: rows.size,
          transactions: rows.map { |tx| transaction_json(tx) }
        }
      end

      # Level-1 drill of the Ausgaben hierarchy: the top Empfänger WITHIN one category,
      # ranked by spend, over the SAME clamped display window/scope as #show's category bar
      # (so Σ items == that category's bar minus its person-transfers — invariant CM1).
      # `category_id` selects the category; `uncategorized=1` ⇒ the null-category bar's
      # Empfänger. Absent-both deliberately resolves to nil → the uncategorized bucket (NOT a
      # global all-merchants list, which is gone, and NOT a 400 — every UI caller always sends
      # category_id or uncategorized=1; review m2). Person-to-person transfers
      # (transfer_group_id present) are dropped — a person name is not a merchant (the
      # intentional CM1 divergence from the category bar). The leaf is now
      # #category_transactions?creditor=… (§2.1), not a `name` drill here. Read-only.
      def merchants
        window        = stats_window(params)[:window]
        uncategorized = params[:uncategorized] == "1"
        category_id   = uncategorized ? nil : params[:category_id].presence

        debits = window.debits
                       .where(category_id: category_id)        # scope to ONE category (CM1)
                       .where(transfer_group_id: nil)          # drop person-to-person transfers
        render json: merchant_items(debits)
      end

      private

      # The display-window construction shared by #show (and #merchants, §2.2): the
      # user-chosen [from, to] period, SF1-floored and I4-clamped, plus the scoped,
      # internal-transfer-excluded `window` relation it produces. Returns everything
      # #show consumes from this block, so the figures reconcile (plan §1.6). The raw
      # `from` is returned alongside `clamped_from` so #show can report `range.clamped`.
      #
      # NB §2.1/n1: #category_transactions deliberately does NOT consume this — it must
      # use the raw passed-in `from` WITHOUT the I4 earliest-tx re-clamp (the frontend
      # already sends the clamped data.range.from), so it keeps its own short block.
      def stats_window(params)
        ids  = scoped_account_ids
        to   = parse_date(params[:to], Date.current)
        from = parse_date(params[:from], to.beginning_of_month - 5.months)
        from = to if from > to
        # SF1: bound the window so a hand-crafted `from` can't drive build_series
        # through thousands of months (the UI only ever requests ≤12-month presets;
        # 36 months is generous headroom). The earliest-tx clamp below narrows further.
        from = [ from, to.advance(months: -36) ].max

        window = in_scope(Current.user.transaction_records.in_period(from, to), ids)

        # I4: clamp the display start to the earliest tx actually in the window, so
        # accounts with shorter history don't render empty leading months.
        earliest = window.minimum(:booking_date)
        clamped_from = earliest && earliest > from ? earliest : from

        { ids: ids, from: from, to: to, window: window,
          clamped_from: clamped_from, months: month_span(clamped_from, to) }
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

      # Squeeze run-length whitespace in card-acquirer names ("VISA   DEBIT  REWE SAGT
      # DANKE" → "VISA DEBIT REWE SAGT DANKE"); blank/whitespace → nil (the null bucket).
      # FULL brand canonicalisation (acquirer prefixes, terminal-suffix variants) is OUT OF
      # SCOPE (plan §2.2) — whitespace squeeze only.
      def normalize_merchant(raw)
        raw.to_s.strip.gsub(/\s+/, " ").presence
      end

      # One ranked list of (already category-scoped) debit spend grouped by NORMALISED
      # creditor_name (plan §2.2). Grouped in Ruby (not SQL) because the whitespace-squeeze
      # rule is a Ruby method; pull the two columns we need and fold — bounded for one
      # category's window. Mirrors category_items minus `id`: BigDecimal discipline (I2),
      # most-negative first, the UN-capped per-category `total` for the footer, capped at
      # TOP_MERCHANTS.
      def merchant_items(debits)
        rows = debits.pluck(:creditor_name, :amount)        # [[name, BigDecimal], ...]
        acc  = Hash.new { |h, k| h[k] = { amount: 0.to_d, count: 0 } }
        rows.each do |name, amount|
          key = normalize_merchant(name)                    # nil-name → nil key (fallback bucket)
          acc[key][:amount] += amount.to_d
          acc[key][:count]  += 1
        end

        items = acc.map { |name, agg| { name: name, amount: agg[:amount], count: agg[:count] } }
        total = items.sum(0.to_d) { |i| i[:amount] }
        denom = total.abs
        items.each { |i| i[:share] = denom.zero? ? 0.0 : (i[:amount].abs / denom * 100).round(1).to_f }
        items.sort_by! { |i| i[:amount] }                   # most-negative (largest spend) first

        { items: items.first(TOP_MERCHANTS), total: total }  # total is the UN-capped figure
      end

      # Forward "typischer Monat" projection — window-INDEPENDENT ("ab heute") but
      # scope-aware (plan §2.1–§2.3). All money serialized as dashboard-style
      # BigDecimal strings (.to_d), so an empty scope renders "0.0", not Integer 0.
      def forecast(ids)
        # Two parts (redesigned with the user 2026-06-10):
        #  • RECURRING (both directions) — reliable, taken at RUN-RATE (current contract
        #    amount), never averaged. flow_bucket(scope_ids:) nets transfers between two
        #    in-scope accounts; with a single-account lens (Gemeinsam = the joint pot) there
        #    are none, so a giro→joint contribution's joint-side inflow leg counts as real
        #    income, and under Privat the giro-side outflow counts as an expense. "expense" here
        #    is ALL recurring outflow incl. Sparen — it's CASHFLOW, not the Fixkosten KPI.
        #  • VARIABLE — the unpredictable one-offs — averaged SYMMETRICALLY (income AND
        #    expenses) over the last months, so a one-off (vacation) and its offset (refund)
        #    net out. Clean partition, NO double-count: recurring_series_id present →
        #    run-rate here; NULL → the variable average. (Preloading members alone is
        #    N+1-free — flow_bucket reads only the FK columns.)
        # scope_ids == ids for BOTH lenses (never nil): under "gemeinsam" the joint-side
        # inflow leg of a contribution (counterpart = the out-of-scope personal giro) must
        # count as recurring income, not be netted to a transfer — nil would re-net it and
        # erase the contribution from rec_income (mirrors bucket_scope_ids in the recurring
        # controller). flow_bucket with these ids nets only transfers between two in-scope
        # accounts; with a single-account scope there are none, so nothing is wrongly netted.
        scope_ids = ids
        series = Current.user.recurring_series.active
                        .merge(RecurringSeries.with_member_in(ids))
                        .includes(:transaction_records)
                        .to_a
        buckets = series.to_h { |s| [ s, s.flow_bucket(members: s.transaction_records.to_a, scope_ids: scope_ids) ] }

        rec_income   = 0.to_d
        rec_expenses = 0.to_d
        # Named per-series monthly run-rates (signed: + income, − expense) so the
        # "Was-wäre-wenn" playground can let the user ADJUST an existing item (Gehalt
        # 1.920 → 3.220) instead of hand-computing the delta. Same source as the totals.
        rec_items = []
        series.each do |s|
          eq = monthly_equiv(s)
          next if eq.nil?

          case buckets[s]
          when "income"  then rec_income   += eq; rec_items << { label: s.canonical_name, monthly: eq.to_f.round(2) }
          when "expense" then rec_expenses -= eq; rec_items << { label: s.canonical_name, monthly: -eq.to_f.round(2) }
          end
        end
        rec_items.sort_by! { |i| -i[:monthly].abs }

        var = variable_averages(ids)
        total_balance = Current.user.accounts.where(id: ids).sum(:balance_amount).to_d
        total_net     = rec_income + rec_expenses + var[:income] + var[:expenses]

        # Liquide lens: the SAME projection over only the spending accounts (drop
        # investment/savings by role). Reusing the scope machinery is the whole trick —
        # with the liquid ids as BOTH the universe AND the flow_bucket scope, a recurring
        # giro→investment Sparplan (its counterpart now OUTSIDE the lens) flips from a
        # netted transfer to a real outflow, so the liquid runway honestly counts money
        # locked away. No investment/savings account ⇒ liquid == total (lens collapses).
        liquid_ids = ids - investment_account_ids
        liquid     = liquid_ids.sort == ids.sort ? { balance: total_balance, net: total_net } : liquid_projection(liquid_ids)

        {
          recurring_income: rec_income,
          recurring_expenses: rec_expenses,
          variable_income: var[:income],
          variable_expenses: var[:expenses],
          avg_window_months: var[:months],
          current_balance: total_balance,
          total_net: total_net,
          liquid_balance: liquid[:balance],
          liquid_net: liquid[:net],
          recurring_items: rec_items,
          upcoming: upcoming_payments(series, buckets)
        }.tap { |f| f[:upcoming_total] = f[:upcoming].sum(0.to_d) { |u| u[:amount] } }
      end

      # Numeric projection (current balance + monthly net = recurring run-rate + variable
      # average) for a liquid sub-universe. scope_ids == ids so flow_bucket treats a
      # transfer to an account OUTSIDE this set (giro→TR) as a real outflow, mirroring
      # in_scope inside variable_averages (the two-classifiers invariant, on the subset).
      def liquid_projection(ids)
        series = Current.user.recurring_series.active
                        .merge(RecurringSeries.with_member_in(ids))
                        .includes(:transaction_records).to_a
        rec = 0.to_d
        series.each do |s|
          eq = monthly_equiv(s)
          next if eq.nil?

          case s.flow_bucket(members: s.transaction_records.to_a, scope_ids: ids)
          when "income"  then rec += eq
          when "expense" then rec -= eq
          end
        end
        var = variable_averages(ids)
        {
          balance: Current.user.accounts.where(id: ids).sum(:balance_amount).to_d,
          net: rec + var[:income] + var[:expenses]
        }
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

      # Verlauf Ø-reference (plan §3.3b/§3b — "ist dieser Monat normal?", answered in the
      # Verlauf chart, NOT on the hero). For each series (income, expenses) over the DISPLAY
      # window's per-month buckets: the trailing Ø = mean of the COMPLETED months (month <
      # current calendar month), and the LAST COMPLETED month's total + their delta. The
      # current (in-progress) month is EXCLUDED from the Ø and is NOT the comparison point —
      # the chart draws it visibly partial (invariants VR1/VR3). Like-for-like
      # full-month-vs-full-month-mean ⇒ no partial-month divisor asymmetry, no salary-timing
      # income noise. Money via .to_d / .round(2) (I2/S2-safe — typed-decimal sums, not raw
      # Arel); scope-aware because the buckets come from the in_scope window (VR2).
      #
      # `months` = the chart's month keys in order (build_series(clamped_from, to)'s "%Y-%m"
      # list); income_by_month / expense_by_month = the existing #show hashes (signed:
      # expenses ≤ 0). Rides on #show — no second fetch, no new query.
      def vs_average(months, income_by_month, expense_by_month)
        cur_key   = Date.current.strftime("%Y-%m")
        completed = months.reject { |m| m >= cur_key }            # months strictly before this one
        last_done = completed.last                                # the like-for-like comparison month

        inc_ref = avg_over(completed, income_by_month)            # mean of completed-month income (≥ 0)
        exp_ref = avg_over(completed, expense_by_month)           # mean of completed-month expenses (≤ 0)
        inc_cur = last_done ? (income_by_month[last_done]  || 0).to_d : 0.to_d
        exp_cur = last_done ? (expense_by_month[last_done] || 0).to_d : 0.to_d
        {
          baseline_months: completed.size,                        # completed months averaged (VR1/VR3)
          last_complete_month: last_done,                         # 'YYYY-MM' or nil — the delta's month
          income:   delta_pair(inc_cur, inc_ref),
          expenses: delta_pair(exp_cur, exp_ref),
          net:      delta_pair(inc_cur + exp_cur, inc_ref + exp_ref)   # derived, not separately summed
        }
      end

      # Mean of a series over the given month keys (BigDecimal; 0 when no months). A month
      # present in the chart but absent from the bucket hash is a real €0 month and counts in
      # the divisor.
      def avg_over(keys, by_month)
        return 0.to_d if keys.empty?

        keys.sum(0.to_d) { |m| (by_month[m] || 0).to_d } / keys.size
      end

      # {current:, baseline:, delta:, pct:} — pct nil when the baseline is zero (no
      # divide-by-zero; the frontend then hides the percent). current/baseline/delta are
      # .round(2) (review n2): BigDecimal÷Integer would otherwise serialize full precision
      # ("663.5933…"), not the clean 2-dp the contract shows — consistent with
      # avg_monthly_expenses/fixed_monthly, which already round(2). pct uses baseline.abs so
      # signed-negative expenses read intuitively (spend MORE → delta < 0 → pct < 0; the
      # frontend maps sign→colour per metric, §3.3 B2).
      def delta_pair(current, baseline)
        current  = current.round(2)
        baseline = baseline.round(2)
        delta    = (current - baseline).round(2)
        pct      = baseline.zero? ? nil : (delta / baseline.abs * 100).round(1).to_f
        { current: current, baseline: baseline, delta: delta, pct: pct }
      end

      # Symmetric average of the UNPREDICTABLE, non-recurring flows over the last
      # FORECAST_WINDOW_MONTHS full calendar months (current partial month excluded):
      # variable income (non-recurring credits) AND variable expenses (non-recurring
      # debits), each ÷ the SAME divisor. Symmetric so a one-off expense (vacation) and its
      # offset (a refund) net out; the window amortises lumps into a sustainable monthly
      # rate. NO weighting — the recency that matters (a raise, a new/cancelled contract) is
      # already in the run-rate; the variable part we deliberately smooth. recurring-linked
      # rows are NOT here (they're the run-rate) → no double-count.
      #
      # ⚠️ Divisor = months that actually HAVE in-scope data (distinct YYYY-MM with ≥1
      # in-scope tx), NEVER a flat FORECAST_WINDOW_MONTHS. A month WITH data but no variable
      # flow IS a real €0 month and counts (pulls the avg down).
      #
      # ⚠️ The window START is also clamped to the LATEST first-transaction among in-scope
      # accounts that have history, capped at FORECAST_WINDOW_MONTHS — we never average a
      # period the DATA-WEAKEST account didn't cover yet. Otherwise a long-history expense
      # card (PayPal/easybank back ~1yr) averaged against a younger income account (a Giro
      # added later) skews the rate — AND pre-Giro months leak phantom "income" (credit-card
      # bill settlements whose paying leg isn't tracked yet → can't be netted). Empty accounts
      # (no tx) don't constrain; the clamp self-relaxes to the full window once every account
      # has ≥FORECAST_WINDOW_MONTHS of history (user rule 2026-06-10).
      def variable_averages(ids)
        w = variable_window(ids)
        divisor = [ w[:months], 1 ].max
        {
          income: (w[:nonrec].credits.sum(:amount).to_d / divisor),
          expenses: (w[:nonrec].debits.sum(:amount).to_d / divisor),
          months: w[:months]
        }
      end

      # The clamped lookback window + scoped, non-recurring relation that BOTH the
      # forecast average and the drill-down modal (#variable_transactions) derive
      # from — so the listed rows always sum to exactly the row shown in the ledger.
      def variable_window(ids)
        cap_from = Date.current.beginning_of_month.prev_month(FORECAST_WINDOW_MONTHS)
        to       = Date.current.beginning_of_month - 1.day
        latest_start = Current.user.transaction_records.where(account_id: ids)
                              .group(:account_id).minimum(:booking_date).values.compact.max
        from   = latest_start ? [ cap_from, latest_start.beginning_of_month ].max : cap_from
        scoped = in_scope(Current.user.transaction_records.in_period(from, to), ids)
        months = scoped.distinct.count(MONTH) # months WITH data in the (clamped) window
        # `scoped` is the ALL-flows trailing relation (recurring + variable); `nonrec`
        # drops recurring (the forecast averages variable only, taken at run-rate). Only the
        # forecast + the variable-flows drill read this — the Verlauf Ø-reference (§3b) uses
        # the DISPLAY window's per-month series instead, so vs_average no longer reads here.
        { from: from, to: to, months: months,
          nonrec: scoped.where(recurring_series_id: nil) }
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
