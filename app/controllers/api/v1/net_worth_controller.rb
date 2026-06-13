module Api
  module V1
    # Net-worth-over-time: a per-account daily balance series (from balance_snapshots),
    # scope-aware. The frontend composes scope / Liquide-Gesamt lens / single-account-or-role
    # isolation by summing whichever SUBSET of accounts is selected, and clamps the combined
    # line to where the selected accounts all have data (NET_WORTH_PLAN §2.3–§2.4). Net worth
    # is a STOCK — we SUM balances; we deliberately do NOT apply the internal-transfer netting
    # (`in_scope`) the cashflow figures use (an internal transfer nets to zero in a balance
    # sum by construction, §2.1).
    class NetWorthController < ApplicationController
      include ScopedAccounts

      def show
        ids  = scoped_account_ids
        to   = parse_date(params[:to], Date.current)
        from = parse_date(params[:from], nil) # nil ⇒ full history (each account's own depth)

        # One query for every in-scope snapshot, bucketed per account (ordered by date).
        by_account = BalanceSnapshot.where(account_id: ids).order(:account_id, :snapshot_on)
                                    .pluck(:account_id, :snapshot_on, :balance_amount)
                                    .group_by(&:first)

        inv_ids  = investment_account_ids.to_set
        accounts = Current.user.accounts.where(id: ids).index_by(&:id)

        series = ids.filter_map do |aid|
          points = by_account[aid]
          next if points.blank?

          daily = carry_forward(points, from, to)
          next if daily.empty?

          acct = accounts[aid]
          {
            id: aid,
            name: acct.display_name,
            role: acct.role,
            investment: inv_ids.include?(aid),
            earliest: daily.first[:date],
            series: daily
          }
        end

        # NW1: latest == the dashboard's total balance for this scope (sum of CURRENT
        # balances; the post-sync hook keeps today's snapshot in step). Summed in Ruby from
        # the accounts already loaded above — no extra SQL, no separate liquid query.
        # balance_amount is nullable → guard; sum(0.to_d) so an empty scope serialises "0.0".
        all_accounts = accounts.values
        total  = all_accounts.sum(0.to_d) { |a| a.balance_amount || 0 }
        liquid = all_accounts.reject { |a| inv_ids.include?(a.id) }.sum(0.to_d) { |a| a.balance_amount || 0 }

        earliests = series.map { |a| a[:earliest] }
        render json: {
          range: { from: earliests.min || to, to: to },
          accounts: series,
          summary: {
            latest: { total: total, liquid: liquid },
            clamped_from: earliests.max # where the whole-scope combined line can start
          }
        }
      end

      private

      # A continuous daily [start, to] series for one account, carrying the latest snapshot
      # ≤ each day forward (so a missed capture day never punches a hole, and a `from` window
      # is seeded with the right opening value). `points` = [[account_id, date, balance], …]
      # ordered by date. `start` is the account's earliest snapshot, clamped up to `from`.
      def carry_forward(points, from, to)
        earliest = points.first[1]
        start = from && from > earliest ? from : earliest
        return [] if start > to

        out = []
        i = 0
        last = nil
        (start..to).each do |day|
          while i < points.length && points[i][1] <= day
            last = points[i][2]
            i += 1
          end
          out << { date: day, balance: last } if last
        end
        out
      end
    end
  end
end
