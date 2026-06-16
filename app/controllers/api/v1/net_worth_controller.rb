module Api
  module V1
    # Net-worth-over-time, scope-aware. Each stored-balance account (giro/sparkonto/
    # kreditkarte) is reconstructed from its transactions — balance(D) = current_balance −
    # Σ(amount where booking_date ≥ D) — so the history is as deep as the imported tx reach.
    # Broker/pass-through accounts (investment depot, PayPal/zahlung) can't be reconstructed
    # from transactions, so they carry from their captured daily snapshots (flat at the
    # earliest snapshot before that, or at the current balance if none).
    #
    # Returns TWO aggregate lines — Liquide (excl. investment/savings) and Gesamt — over the
    # window where every reconstructable in-scope account has data, plus today's composition.
    # Scope = account MEMBERSHIP (Gemeinsam = shared, Privat = personal); net worth is a STOCK, so
    # we SUM balances and do NOT apply the cashflow's internal-transfer netting. NW1: the
    # `latest` totals equal the dashboard's balance for the same scope.
    class NetWorthController < ApplicationController
      include ScopedAccounts

      # Flat-fill ONLY these (their tx feed doesn't represent a stored balance); reconstruct
      # everything else WITH transactions — including a giro whose role-inferrer hasn't run
      # (role=nil), so a real account is never silently flattened to a horizontal line.
      NON_RECONSTRUCTABLE_ROLES = %w[investment zahlung].freeze

      def show
        ids      = scoped_account_ids
        to       = parse_date(params[:to], Date.current)
        from     = parse_date(params[:from], nil) # nil ⇒ as deep as the data reaches
        accounts = Current.user.accounts.where(id: ids).to_a
        invest   = investment_account_ids.to_set

        built = accounts.to_h { |a| [ a, build(a, to) ] }
        # The combined line can only start where every RECONSTRUCTABLE account has data;
        # broker/pass-through accounts flat-fill back to that start, so they don't constrain it.
        recon_starts = built.values.select { |b| b[:reconstructable] }.filter_map { |b| b[:earliest] }
        start = recon_starts.max || built.values.filter_map { |b| b[:earliest] }.min || to
        start = [ start, from ].max if from

        return render(json: empty_payload(to)) if accounts.empty? || start > to

        daily   = built.transform_values { |b| densify(b, start, to) }
        liquids = accounts.reject { |a| invest.include?(a.id) }
        series  = (start..to).map do |d|
          {
            date: d,
            liquid: liquids.sum(0.to_d) { |a| daily[a][d] },
            total: accounts.sum(0.to_d) { |a| daily[a][d] }
          }
        end

        # NW1: latest == the dashboard's total balance for the scope (the live current balances).
        total_now  = accounts.sum(0.to_d) { |a| a.balance_amount || 0 }
        liquid_now = liquids.sum(0.to_d) { |a| a.balance_amount || 0 }
        # Pin the final point to those live balances: reconstruction yields the START-OF-DAY
        # value for `to` (it omits transactions booked today), which would otherwise leave the
        # chart's right edge a day's-bookings above the "Vermögen heute" headline beneath it.
        if (today_point = series.last)
          today_point[:total]  = total_now
          today_point[:liquid] = liquid_now
        end

        render json: {
          range: { from: start, to: to },
          series: series,
          latest: { total: total_now, liquid: liquid_now },
          composition: accounts.map { |a| { name: a.display_name, role: a.role, balance: (a.balance_amount || 0).to_d } }
        }
      end

      private

      # Reconstruction inputs for one account. Stored-balance accounts get a date→balance
      # hash walked back from the current balance over booked transactions; the rest get
      # their captured snapshots + a flat anchor (the earliest snapshot, else current).
      def build(account, to)
        current = (account.balance_amount || 0).to_d
        by_day = if NON_RECONSTRUCTABLE_ROLES.include?(account.role)
                   {}
                 else
                   # booked-only: the current balance (our anchor) reflects booked tx, so a
                   # pending row with a booking_date would drift the reconstruction from it.
                   account.transaction_records.booked.where.not(booking_date: nil).group(:booking_date).sum(:amount)
                 end
        if by_day.any?
          earliest = by_day.keys.min
          recon = {}
          ge = 0.to_d
          (earliest..to).reverse_each do |d|
            ge += (by_day[d] || 0)
            recon[d] = current - ge
          end
          { reconstructable: true, earliest: earliest, recon: recon, current: current }
        else
          # broker/pass-through (or a reconstructable account with no tx): carry from captured
          # snapshots, flat at the earliest one before that (else the current balance).
          snaps = account.balance_snapshots.order(:snapshot_on).pluck(:snapshot_on, :balance_amount)
          { reconstructable: false, earliest: snaps.first&.first, snaps: snaps, anchor: (snaps.first&.last || current), current: current }
        end
      end

      # Dense date→balance over [start, to] for one account.
      def densify(b, start, to)
        out = {}
        if b[:reconstructable]
          (start..to).each { |d| out[d] = b[:recon][d] || b[:current] }
        else
          i = 0
          val = b[:anchor]
          (start..to).each do |d|
            while i < b[:snaps].length && b[:snaps][i][0] <= d
              val = b[:snaps][i][1]
              i += 1
            end
            out[d] = val
          end
        end
        out
      end

      def empty_payload(to)
        { range: { from: to, to: to }, series: [], latest: { total: 0.to_d, liquid: 0.to_d }, composition: [] }
      end
    end
  end
end
