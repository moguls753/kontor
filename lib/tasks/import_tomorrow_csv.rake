require "csv"

# One-time import of a Tomorrow Banking CSV export to DEEPEN giro history beyond what
# Enable Banking synced (the live sync only reaches ~3 months; the export covers ~6+).
# Deeper giro history → the net-worth chart reaches further (it reconstructs the line live
# from these transactions; there is no separate backfill step to run).
#
# ── ROUTING ──────────────────────────────────────────────────────────────────
# Each CSV is single-account: rows carry account_type "Personal Account" or
# "Shared account". We route to the matching giro: Personal → the user's non-shared
# giro, Shared → the shared giro. (Verified against the account IBANs.)
#
# ── DEDUP (fundamentals, like EnableBanking::TransactionIngest) ───────────────
# Tomorrow rows have NO stable id, so we can't key on one. We match each CSV row to
# an existing transaction by (booking_date, signed amount), disambiguating ties by
# remittance, and CLAIM-track so two CSV rows can't map to one stored row. A match ⇒
# the row is already synced (the Mar–Jun overlap) ⇒ skip. No match ⇒ it's new
# (Dec–early-Mar) ⇒ import. Imported rows get an `eb-gen-` surrogate id so a later
# EB re-sync treats them exactly like its own surrogates (reconcilable, never duped).
#
# ── NOT DONE HERE ─────────────────────────────────────────────────────────────
# Categorisation / transfer-matching / recurring detection / snapshot backfill — run
# those AFTER (the task prints the commands). Imported rows arrive uncategorised so
# the app's categoriser treats them uniformly with synced rows.
#
#   CSV=tmp/personal.csv bin/rails tomorrow:import_csv            # dry-run
#   CSV=tmp/personal.csv APPLY=1 bin/rails tomorrow:import_csv    # import
#
namespace :tomorrow do
  desc "Import a Tomorrow Banking CSV export into the matching giro (dedup vs synced tx)"
  task import_csv: :environment do
    apply = ENV["APPLY"] == "1"
    path  = ENV["CSV"] or abort "Set CSV=<path to a Tomorrow export>."
    abort "No such file: #{path}" unless File.exist?(path)

    rows = CSV.read(path, headers: true)
    abort "Empty CSV." if rows.empty?

    # Route by account_type → the matching giro (must be exactly one).
    types = rows.map { |r| r["account_type"].to_s.strip }.uniq
    abort "Mixed/unknown account_type in CSV: #{types.inspect}" unless types.size == 1
    shared = types.first.casecmp?("Shared account")
    giros  = Account.where(role: "giro", shared: shared).to_a
    abort "Expected exactly one #{shared ? 'shared' : 'personal'} giro, found #{giros.size}." unless giros.size == 1
    account = giros.first

    puts(apply ? "APPLY — importing into ##{account.id} #{account.display_name}" : "DRY-RUN — nothing written (pass APPLY=1)")
    puts "CSV: #{path} (#{rows.size} rows, account_type=#{types.first} → account ##{account.id})"

    # Existing rows bucketed by [booking_date, amount] for fundamental dedup; claim-tracked.
    existing = Hash.new { |h, k| h[k] = [] }
    account.transaction_records.pluck(:id, :booking_date, :amount, :remittance).each do |id, bd, amt, rem|
      existing[[ bd, amt ]] << { id: id, remittance: rem }
    end
    claimed = Set.new

    to_create = []
    skipped = 0
    errors  = 0
    rows.each.with_index(2) do |row, line| # CSV line number (header = line 1)
      begin
        # STRICT ISO (YYYY-MM-DD): Date.parse is locale-heuristic and would silently read a
        # slash format as M/D, mis-dating every row and breaking dedup. iso8601 raises instead.
        bd   = Date.iso8601(row["booking_date"])
        amt  = parse_de_amount(row["amount"])
        desc = row["description"].to_s
        cands = existing[[ bd, amt ]].reject { |e| claimed.include?(e[:id]) }
        match = cands.find { |e| e[:remittance].to_s == desc } || cands.first
        if match
          claimed << match[:id]
          skipped += 1
          next
        end
        who   = row["sender_or_recipient"].presence
        iban  = row["iban"].presence
        debit = amt.negative?
        to_create << {
          account_id: account.id,
          transaction_id: "eb-gen-#{SecureRandom.uuid}",
          amount: amt,
          currency: row["currency"].presence || "EUR",
          booking_date: bd,
          value_date: (Date.iso8601(row["valuta_date"]) rescue nil),
          status: "booked",
          remittance: desc,
          bank_transaction_code: row["booking_type"].presence,
          creditor_name: debit ? who : nil,
          creditor_iban: debit ? iban : nil,
          debtor_name:   debit ? nil : who,
          debtor_iban:   debit ? nil : iban
        }
      rescue StandardError => e
        # One malformed cell must never abort a 6-month import; skip + report the line.
        errors += 1
        warn "  ! line #{line} skipped (#{e.class}): booking_date=#{row['booking_date'].inspect} amount=#{row['amount'].inspect}"
      end
    end

    new_dates = to_create.map { |r| r[:booking_date] }
    puts "  matched existing (skipped as already-synced): #{skipped}"
    puts "  malformed rows skipped: #{errors}" if errors.positive?
    puts "  NEW to import: #{to_create.size}" + (new_dates.any? ? "  (#{new_dates.min} … #{new_dates.max})" : "")
    to_create.first(4).each { |r| puts "    + #{r[:booking_date]}  #{format('%9.2f', r[:amount])}  #{r[:remittance].to_s[0, 40]}" }
    puts "    …" if to_create.size > 4
    # Sanity: if almost nothing matched, the overlap wasn't recognised (date-format or dedup
    # problem) and APPLY would DUPLICATE — investigate before writing.
    puts "  ⚠ almost no overlap matched — suspect a date/format or dedup issue; do NOT APPLY yet." if rows.size > 20 && skipped < rows.size / 10

    if apply && to_create.any?
      now = Time.current
      TransactionRecord.insert_all(to_create.map { |r| r.merge(created_at: now, updated_at: now) })
      puts "Imported #{to_create.size} rows. Next: re-categorise/match/detect (\"Neu berechnen\") so the new"
      puts "rows are categorised for the cashflow tabs — the net-worth chart already reflects them (live)."
    elsif !apply
      puts "Dry-run only. Re-run with APPLY=1 to import."
    end
  end

  # German money: "-1.234,56" → -1234.56 (drop thousands dots, comma → decimal point).
  def parse_de_amount(str)
    BigDecimal(str.to_s.strip.delete(".").tr(",", "."))
  end
end
