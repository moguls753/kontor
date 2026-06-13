# One-time backfill of historical balance_snapshots, so the net-worth-over-time
# chart is rich from day one instead of starting at the few days the daily
# SnapshotBalancesJob has captured (it only began on 2026-06-09).
#
# ── PER-ACCOUNT DEPTH ────────────────────────────────────────────────────────
# Snapshots are stored per account, and the chart is sliceable by scope
# (Familie/Privat) and by account/role ("nur easybank", "nur giro", "nur TR") —
# all just SUBSETS of accounts summed at read time. So each account is
# reconstructed back to ITS OWN earliest transaction, preserving full per-account
# history (easybank/PayPal ~1yr; the giro/Tomorrow accounts ~3mo). The read-time
# clamp starts each combined line where every SELECTED account has data.
#
# ── RECONSTRUCTION (deterministic for transaction accounts) ──────────────────
# For an account WITH transactions, the balance at the START of day D — the
# convention the real 04:50 snapshots follow, verified against prod — is:
#
#     balance(D) = current_balance − Σ(amount where booking_date ≥ D)
#
# i.e. peel today's reported balance back one day at a time by un-applying each
# day's bookings. Exact given the transactions we hold (all 'booked'): giro is
# fully deterministic, PayPal/easybank we have the full statement. The LEFTMOST
# point is the account's OPENING balance (before its first booking) — possibly
# substantial; an account isn't born at 0.
#
# ── BALANCE-ONLY BROKER ACCOUNTS (assumed constant) ──────────────────────────
# An account with NO transactions (a Trade Republic depot — ETFs/Aktien whose
# value is market-driven, not transaction-driven) CANNOT be reconstructed; its
# past value is genuinely unknowable from our data. For now we simply ASSUME IT
# WAS CONSTANT across the past year, at its earliest known balance — a deliberate,
# accepted simplification (the total line treats the depot as a flat pedestal in
# the past). Real snapshots accumulate going forward every time we sync it, so the
# assumption only ever covers the pre-snapshot past.
#
# ── SAFETY ───────────────────────────────────────────────────────────────────
# Idempotent. Existing snapshots are never overwritten — only missing (account,
# day) pairs are written. Re-running is a no-op. Dry-run by default (writes
# nothing); pass APPLY=1 to commit. The dry-run prints a per-account 'tx↔bal gap'
# (do booked tx explain the moves between snapshots) so an import gap shows first.
#
#   bin/rails snapshots:backfill           # dry-run: plan + integrity check
#   APPLY=1 bin/rails snapshots:backfill   # write the missing rows
#
namespace :snapshots do
  desc "Backfill historical balance_snapshots by walking transactions back from current balance"
  task backfill: :environment do
    apply = ENV["APPLY"] == "1"
    today = Date.current

    first_tx = TransactionRecord.where.not(booking_date: nil).group(:account_id).minimum(:booking_date)
    if first_tx.empty?
      puts "No transactions in the database — nothing to backfill."
      next
    end

    # tx accounts reconstruct to their own first tx; balance-only broker accounts are
    # assumed constant back to the earliest transaction of any account ("the past year").
    earliest = first_tx.values.min
    horizon  = first_tx.values.max   # where the default (giro-limited) total line starts

    puts(apply ? "APPLY — writing missing snapshot rows" : "DRY-RUN — nothing will be written (pass APPLY=1 to commit)")
    puts "Reconstructable history reaches back to #{earliest}; default total line starts #{horizon} (giro-limited)."
    puts "Balance-only broker accounts are assumed constant before their first real snapshot."
    puts
    puts "  acct  name                    from        source          rows  tx↔bal gap"
    puts "  ────  ──────────────────────  ──────────  ──────────────  ────  ──────────"

    written = 0

    Account.where.not(balance_amount: nil).order(:id).find_each do |account|
      current = account.balance_amount
      by_day  = account.transaction_records.where.not(booking_date: nil).group(:booking_date).sum(:amount)
      has_tx  = by_day.any?

      # tx account → reconstruct from its OWN first transaction. Balance-only broker (no tx,
      # market-driven value we cannot compute) → assume CONSTANT across the deepest history,
      # at its earliest known balance; real snapshots accumulate going forward as we sync it.
      start = has_tx ? first_tx[account.id] : earliest
      days  = (start..today).to_a
      flat  = account.balance_snapshots.order(:snapshot_on).pick(:balance_amount) || current

      # Walk newest → oldest, accumulating Σ(amount where booking_date ≥ D), so each day's
      # start-of-day balance is one subtraction; flat-fill the broker. The LEFTMOST point is
      # the OPENING balance (before the first booking) — can be substantial.
      recon  = {}
      ge_sum = 0.to_d
      days.reverse_each do |d|
        ge_sum += (by_day[d] || 0) if has_tx
        recon[d] = has_tx ? (current - ge_sum) : flat
      end

      # Integrity check: do the booked transactions explain the balance moves between
      # consecutive snapshots? For snapshots D1<D2, the tx in [D1, D2) should equal
      # balance(D2) − balance(D1). ≈0 = clean (giro/PayPal/CC are deterministic); a residual
      # flags a market move on the no-tx broker, or a missing/mis-signed row worth a look.
      # REPORTING-ONLY (printed, never written) — read its SHAPE, not magnitude. On a re-run
      # the reconstructed pairs contribute exactly 0 by construction; the single backfill→real
      # boundary pair carries that day's booked-amount anchor skew (a today-anchor artifact,
      # not a data problem), and being a .max can sit above a smaller genuine gap — so the
      # signal is a SUDDEN jump on an otherwise-clean line, not the absolute number.
      snaps = account.balance_snapshots.order(:snapshot_on).pluck(:snapshot_on, :balance_amount)
      gap   = snaps.each_cons(2).map { |(d1, b1), (d2, b2)|
        ((b2 - b1) - by_day.select { |d, _| d >= d1 && d < d2 }.sum(0.to_d) { |_, a| a }).abs
      }.max || 0.to_d

      # Write only days we don't already have, and NEVER `today`: the daily job (and the
      # post-sync hook) own today's row with the live balance — a reconstructed start-of-day
      # value written here could disagree with the live NW1 total until the next capture.
      # (today stays in `recon` so the walk's ge_sum is correct for yesterday; just unwritten.)
      have = account.balance_snapshots.where(snapshot_on: days).pluck(:snapshot_on)
      rows = (recon.keys - have - [ today ]).map do |d|
        { account_id: account.id, snapshot_on: d, balance_amount: recon[d], currency: account.currency }
      end
      BalanceSnapshot.upsert_all(rows, unique_by: %i[account_id snapshot_on]) if apply && rows.any?
      written += rows.size if apply

      source = has_tx ? "#{by_day.size} tx days" : "flat (assumed)"
      printf("  %4d  %-22.22s  %-10s  %-14s  %4d  €%s\n", account.id, account.display_name, start.to_s, source, rows.size, format("%.2f", gap))
    end

    puts
    if apply
      puts "Wrote #{written} new snapshot rows. Existing snapshots preserved. Safe to re-run."
    else
      puts "Dry-run only. 'tx↔bal gap' = unexplained moves between snapshots (≈0 = clean;"
      puts "large = the broker's market move, or an import gap worth a look). APPLY=1 to write."
    end
  end
end
