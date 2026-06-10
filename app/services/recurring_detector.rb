require "digest"
require "set"
require "bigdecimal"

class RecurringDetector
  LOOKBACK_DAYS    = 540
  MIN_OCCURRENCES  = 3
  MIN_CADENCE_DAYS = 5   # drop sub-weekly = habitual spend (Plaid gas/coffee/groceries exclusion)
  AMOUNT_TOLERANCE = 0.15
  CV_MAX           = 0.35
  BUCKET_SHARE_MIN = 0.7
  GAP_FLOOR        = 0.50 # €0.50 amount-cluster split / match floor

  CADENCE_BUCKETS = {
    weekly:    (5..9),
    biweekly:  (12..16),
    monthly:   (24..38),  # wide: calendar months (28–31) + weekend shift
    quarterly: (80..100),
    yearly:    (330..400)
  }.freeze

  CADENCE_DAYS = {
    "weekly" => 7, "biweekly" => 14, "monthly" => 30,
    "quarterly" => 91, "yearly" => 365, "irregular" => nil
  }.freeze

  def initialize(user)
    @user = user
  end

  def detect
    @claimed = Set.new # #1 — reset claim tracking per run (was lazy-||='d at match sites)

    candidates = load_candidates

    # ── Resolve names (LLM canonicalizer) ──────────────────────────────────────
    rows = candidates.map { |tx| build_row(tx) }.compact
    # only name-derived norm_keys go to the LLM; IBAN-only rows group internally (#5)
    norm_keys = rows.map { |r| r[:norm_key] }.compact.uniq
    res = MerchantCanonicalizer.new(@user).resolve(norm_keys)
    canonicals = res[:canonicals]

    detected_count = 0
    ended_count = 0

    # #7 — clear-before-relink ATOMIC with the relink: wrap the whole mutating
    # sequence (global clear, per-series upsert/match/relink, reconcile) in ONE
    # outer transaction so a raise mid-run never strands members with nil links.
    RecurringSeries.transaction do
      # §5.6 Pre-step 0 — canonical upgrade reconciliation (re-point/merge) BEFORE clustering
      reconcile_canonical_upgrades(res[:upgrades])

      rows.each do |r|
        if r[:norm_key].present?
          c = canonicals[r[:norm_key]] || {}
          r[:canonical] = (c[:canonical].presence || r[:norm_key].titleize)
          r[:merchant_type] = c[:type]
        else
          # IBAN-only row: group by its counterparty IBAN, never sent to the LLM (#5)
          r[:canonical] = r[:group_key]
          r[:merchant_type] = nil
        end
      end

      # A4 — clear-before-relink: detach this user's stale links once
      series_ids = @user.recurring_series.ids
      TransactionRecord.where(recurring_series_id: series_ids).update_all(recurring_series_id: nil) if series_ids.any?

      detected_series_ids = Set.new # #3 — key reconcile on SERIES ID, not fingerprint

      # §5.3/§5.4 — partition by [direction, currency], group by [canonical, account].
      # account_id is in the key so a series is ACCOUNT-COHERENT: a payer's payments on a
      # personal account must NOT merge with the same payer's payments on the joint account.
      # The cross-account merge wrongly pulled a joint-only inflow into the Privat scope (a
      # one-off PayPal payment dragged Katja's whole joint contribution into Privat). With
      # the split, a lone cross-account occurrence forms its own group → too few to build a
      # regular series → stays unmatched, and the scoping (with_member_in) is auto-correct.
      rows.group_by { |r| [ r[:direction], r[:currency] ] }.each do |(direction, currency), part_rows|
        part_rows.group_by { |r| [ r[:canonical], r[:account_id] ] }.each do |(canonical, _account_id), group_rows|
          clusters = amount_subcluster(group_rows)
          clusters.each do |cluster|
            series = build_series(cluster, direction:, currency:, canonical:)
            # Outlier rescue: a cluster can fail regularity because a ONE-OFF payment to the
            # same payee fell within §5.3's amount-tolerance band of a recurring fixed amount
            # (e.g. a single Nebenkosten-Nachzahlung next to the monthly rent). Retry on the
            # dominant exact-amount sub-group so the genuine fixed-amount series is still found;
            # the one-off stays unmatched (it is NOT folded into the series).
            if series.nil? && (mode = dominant_amount_subgroup(cluster))
              series = build_series(mode, direction:, currency:, canonical:)
            end
            next unless series

            persisted = persist_series(series, direction:, currency:, canonical:)
            next unless persisted

            detected_series_ids << persisted.id # #3
            detected_count += 1
          end
        end
      end

      # §5.6 step 5 — reconcile vanished active series → ended (end-grace)
      ended_count = reconcile_vanished(detected_series_ids)
    end

    active = @user.recurring_series.active.count
    {
      detected: detected_count,
      active:,
      ended: ended_count,
      series: @user.recurring_series.active.order(next_expected_on: :asc).map { |s| serialize(s) }
    }
  end

  private

  # ── Candidate loading ────────────────────────────────────────────────────────

  def load_candidates
    own_ibans = @user.accounts.pluck(:iban).compact.map(&:downcase).uniq

    scope = @user.transaction_records
                 .booked
                 .where(booking_date: LOOKBACK_DAYS.days.ago.to_date..)

    # S3 — drop own-account transfers in SQL (best-effort; account IBANs often NULL).
    # Check ONLY the COUNTERPARTY side per direction: outflow→creditor, inflow→debtor.
    # The self side (e.g. debtor_iban on an outflow) is the user's OWN account IBAN on
    # real Enable-Banking data, so a both-sides check would wrongly exclude every booked
    # outflow. IS NOT NULL keeps the predicate NULL-safe. Windowed load is inherent.
    #
    # transfer_group_id IS NULL guard: a MATCHED internal transfer (paired by the
    # TransferMatcher, which ran before this in the pipeline) must NOT be dropped — it
    # has to reach detection so flow_bucket can place it in the Transfers tab. Without this
    # guard, fixing the account IBANs (which makes own_ibans non-empty) would silently
    # swallow every recurring internal transfer.
    # Only UNMATCHED own-account transfers are still dropped here (anti-clutter, as before).
    if own_ibans.any?
      scope = scope.where(
        "NOT ( transfer_group_id IS NULL AND ( " \
        "(amount < 0 AND creditor_iban IS NOT NULL AND LOWER(creditor_iban) IN (:i)) " \
        "OR (amount >= 0 AND debtor_iban IS NOT NULL AND LOWER(debtor_iban) IN (:i)) ) )",
        i: own_ibans
      )
    end

    scope.to_a
  end

  def build_row(tx)
    direction = tx.amount.negative? ? "outflow" : "inflow"
    cp_iban   = (direction == "outflow" ? tx.creditor_iban : tx.debtor_iban)
    raw = counterparty_raw(tx, direction)
    norm_key = MerchantNormalizer.call(raw)

    # #5 — no name-derived key: keep IBAN-only rows groupable internally via the
    # counterparty IBAN (never sent to the canonicalizer / LLM). Drop only if
    # there is neither a usable name nor an IBAN to group on.
    group_key = norm_key.presence || cp_iban.presence
    return nil if group_key.blank?

    {
      tx_id: tx.id,
      account_id: tx.account_id,
      amount: tx.amount,
      booking_date: tx.booking_date,
      currency: tx.currency,
      direction:,
      norm_key: norm_key.presence, # nil for IBAN-only rows → excluded from LLM batch
      group_key:,                  # internal grouping fallback (IBAN), never LLM-bound
      counterparty_iban: cp_iban,
      category_id: tx.category_id
    }
  end

  # fallback chain for the LLM norm_key: payee name → other name → remittance token.
  # #5 — a raw IBAN is NEVER returned here (it must not become a norm_key sent to the
  # LLM); IBAN-only rows are grouped internally via build_row's group_key.
  def counterparty_raw(tx, direction)
    primary = direction == "outflow" ? tx.creditor_name : tx.debtor_name
    other   = direction == "outflow" ? tx.debtor_name : tx.creditor_name
    primary.presence || other.presence ||
      tx.remittance.to_s.split(/\s+/).first.presence
  end

  # ── §5.3 amount sub-clustering ────────────────────────────────────────────────
  # split into clusters where gap between successive amounts > max(TOL*amount, €0.50)
  def amount_subcluster(rows)
    sorted = rows.sort_by { |r| r[:amount].abs }
    clusters = []
    current = []
    prev = nil
    sorted.each do |r|
      a = r[:amount].abs
      if prev && (a - prev) > [ AMOUNT_TOLERANCE * a, GAP_FLOOR ].max
        clusters << current
        current = []
      end
      current << r
      prev = a
    end
    clusters << current unless current.empty?
    clusters
  end

  # Outlier rescue (used only when a cluster failed to yield a regular series): the rows of
  # the single most-frequent EXACT amount, IF it recurs often enough to stand alone. Lets a
  # fixed-amount recurring payment (rent) survive a one-off payment to the same payee that
  # landed within §5.3's amount-tolerance band. Returns nil for a single-amount cluster
  # (retry would be identical) or when no amount reaches MIN_OCCURRENCES.
  def dominant_amount_subgroup(cluster)
    by_amount = cluster.group_by { |r| r[:amount] }
    return nil if by_amount.size < 2

    _amount, mode_rows = by_amount.max_by { |_amt, rs| rs.size }
    mode_rows if mode_rows.size >= MIN_OCCURRENCES
  end

  # ── build candidate series from a cluster (§5.1, §5.2, §5.4, §5.5) ────────────
  def build_series(cluster, direction:, currency:, canonical:)
    members = cluster.sort_by { |r| r[:booking_date] }
    dates   = members.map { |r| r[:booking_date] }
    amounts = members.map { |r| r[:amount] }
    return nil if members.size < MIN_OCCURRENCES

    deltas = dates.each_cons(2).map { |a, b| (b - a).to_i }
    return nil if deltas.empty?

    med = median(deltas)
    mean = deltas.sum.to_f / deltas.size
    cv = mean.zero? ? 0.0 : (stddev(deltas) / mean)

    cadence, bucket_range = classify_cadence(med)
    share = if bucket_range
      deltas.count { |d| bucket_range.include?(d) }.to_f / deltas.size
    else
      0.0
    end
    regular = (cv <= CV_MAX) || (share >= BUCKET_SHARE_MIN)

    # §5.2 amount analysis (signed)
    expected_amount = median(amounts)
    min_a = amounts.min
    max_a = amounts.max
    span  = expected_amount.abs.zero? ? 0.0 : (max_a - min_a).abs / expected_amount.abs
    amount_variable = span > AMOUNT_TOLERANCE

    # keep-rule (§5.1): bucket != irregular && regular && med >= MIN_CADENCE_DAYS.
    # Lever A — irregular series are NEVER kept (a Vertrag is by definition regelmäßig;
    # the prior "amount-stable + occ>=4" edge-allowance let one-off-ish chains like
    # train tickets / supermarket runs slip through as false positives).
    keep = cadence != "irregular" && regular && med >= MIN_CADENCE_DAYS
    return nil unless keep

    iban_consistent = begin
      ibans = members.map { |r| r[:counterparty_iban].presence }.compact
      ibans.any? && ibans.uniq.size == 1
    end

    confidence = compute_confidence(
      occurrences: members.size, cv:, amount_variable:, iban_consistent:
    )

    last_seen_on  = dates.last
    first_seen_on = dates.first
    anchor_day    = modal_day_of_month(dates)
    next_expected = predict_next(cadence, last_seen_on, anchor_day, med)

    {
      member_ids: members.map { |r| r[:tx_id] },
      category_ids: members.map { |r| r[:category_id] },
      cadence:,
      cadence_days: med,
      expected_amount:,
      amount_variable:,
      amount_min: min_a,
      amount_max: max_a,
      confidence:,
      occurrences_count: members.size,
      first_seen_on:,
      last_seen_on:,
      next_expected_on: next_expected,
      merchant_type: members.map { |r| r[:merchant_type] }.compact.first
    }
  end

  # ── §5.1 cadence classification ───────────────────────────────────────────────
  def classify_cadence(med)
    CADENCE_BUCKETS.each do |name, range|
      return [ name.to_s, range ] if range.include?(med)
    end
    [ "irregular", nil ]
  end

  # ── §5.4 confidence ───────────────────────────────────────────────────────────
  def compute_confidence(occurrences:, cv:, amount_variable:, iban_consistent:)
    # Recalibrated (Divisor 8): the real signals (regularity, fixed amount, same IBAN) carry the
    # score so a regular fixed-amount IBAN-consistent series reaches "high" (>=0.66) at ~4 occurrences,
    # instead of needing ~8 months of history. Volume tops out by ~8 occurrences.
    score  = clamp(occurrences / 8.0, 0, 1) * 0.20    # volume
    score += (1 - clamp(cv, 0, 1)) * 0.35             # regularity — the strongest real signal
    score += amount_variable ? 0.10 : 0.25            # amount stability
    score += iban_consistent ? 0.20 : 0.0             # same counterparty IBAN
    clamp(score, 0, 1).round(3)
  end

  # ── §5.5 next-expected prediction (calendar-aware + month-end rollover) ───────
  def predict_next(cadence, last_seen_on, anchor_day, med = nil)
    return nil if last_seen_on.nil?
    case cadence
    when "weekly"    then last_seen_on + 7
    when "biweekly"  then last_seen_on + 14
    when "monthly"   then month_anchor(last_seen_on, 1, anchor_day)
    when "quarterly" then month_anchor(last_seen_on, 3, anchor_day)
    when "yearly"    then begin last_seen_on.next_year rescue last_seen_on + 365 end
    else
      # #2 — irregular fallback: use the actual median delta, not a hardcoded +30d
      med.to_i.positive? ? last_seen_on + med.to_i : nil
    end
  end

  # N4: target a fixed anchor_day, clamp to days-in-month, no drift
  def month_anchor(from, months_ahead, anchor_day)
    base = from >> months_ahead # Date#>> adds calendar months
    day  = [ anchor_day, Date.new(base.year, base.month, -1).day ].min
    Date.new(base.year, base.month, day)
  end

  def modal_day_of_month(dates)
    dates.map(&:day).group_by(&:itself).max_by { |_d, occ| occ.size }.first
  end

  # ── §5.6 stateful persistence (B2′ gap-consistent nearest-amount match) ───────
  def persist_series(series, direction:, currency:, canonical:)
    # #7 — no inner transaction: detect wraps the whole mutating sequence in ONE
    # outer RecurringSeries.transaction so the clear-before-relink is atomic with
    # the per-series persist/match/relink. A raise here rolls back the entire run.
    fp = RecurringSeries.fingerprint_for(direction, currency, canonical)

    existing = @user.recurring_series.where(fingerprint: fp).to_a

    match = nearest_amount_match(series[:expected_amount], existing)

    if match
      # respect dismissed — skip entirely
      return nil if match.status == "dismissed"

      upsert_stats(match, series, direction:, currency:, canonical:, fp:)
      persisted = match
    else
      persisted = RecurringSeries.new(
        user: @user,
        fingerprint: fp,
        direction:,
        currency:,
        canonical_name: canonical
      )
      upsert_stats(persisted, series, direction:, currency:, canonical:, fp:)
    end

    # one-claim-per-row tracking (within this run); @claimed reset in #detect (#1)
    @claimed << persisted.id

    # link members
    TransactionRecord.where(id: series[:member_ids]).update_all(recurring_series_id: persisted.id)

    persisted
  end

  # B2′: minimum |gap| within max(TOL*amount, €0.50) — the SAME threshold §5.3 split on.
  # tie-break lowest id; one claim per row per run.
  def nearest_amount_match(expected_amount, existing)
    threshold = [ AMOUNT_TOLERANCE * expected_amount.abs, GAP_FLOOR ].max
    eligible = existing
               .reject { |s| @claimed.include?(s.id) }
               .map { |s| [ s, (expected_amount - (s.expected_amount || 0)).abs ] }
               .select { |(_s, gap)| gap <= threshold }
    return nil if eligible.empty?
    eligible.min_by { |(s, gap)| [ gap, s.id ] }.first
  end

  def upsert_stats(row, series, direction:, currency:, canonical:, fp:)
    row.canonical_name    = canonical if row.canonical_name.blank?
    row.merchant_type     = series[:merchant_type] if row.merchant_type.blank?
    row.direction         = direction
    row.currency          = currency
    row.fingerprint       = fp
    row.status            = "active"
    row.cadence           = series[:cadence]
    row.cadence_days      = series[:cadence_days]
    row.expected_amount   = series[:expected_amount]
    row.amount_variable   = series[:amount_variable]
    row.amount_min        = series[:amount_min]
    row.amount_max        = series[:amount_max]
    row.confidence        = series[:confidence]
    row.occurrences_count = series[:occurrences_count]
    row.first_seen_on     = series[:first_seen_on]
    row.last_seen_on      = series[:last_seen_on]
    row.next_expected_on  = series[:next_expected_on]
    # #11 — inherit dominant category in-memory BEFORE the upsert save! so first
    # inheritance is a single write (not save! + a separate update_column).
    # Re-runs short-circuit: a user-set / already-inherited category is never clobbered.
    inherit_category(row, series[:category_ids])
    row.save!
  end

  # #11 — sets row.category_id in memory (caller persists via the upsert save!).
  def inherit_category(row, category_ids)
    return if row.category_id.present? # never clobber a user-set / inherited category
    ids = Array(category_ids).compact
    return if ids.empty?
    dominant = ids.group_by(&:itself).max_by { |_id, occ| occ.size }.first
    row.category_id = dominant if dominant
  end

  # ── §5.6 Pre-step 0 — canonical upgrade reconciliation (re-point/merge) ───────
  def reconcile_canonical_upgrades(upgrades)
    return if upgrades.blank?

    # #7 — no inner transaction: runs inside #detect's single outer tx so any raise
    # here rolls the whole run back rather than committing a partial upgrade.
    upgrades.each do |u|
      old_canonical = u[:old_canonical]
      new_canonical = u[:new_canonical]
      next if old_canonical.blank? || old_canonical == new_canonical

      # #9 — look up the old series by FINGERPRINT (per direction/currency present),
      # NOT by LOWER(canonical_name): a user-renamed series keeps its fingerprint via
      # the model's before_save sync, so the name-keyed lookup would miss it.
      old_fingerprints = @user.recurring_series
                              .distinct
                              .pluck(:direction, :currency)
                              .map { |direction, currency| RecurringSeries.fingerprint_for(direction, currency, old_canonical) }
                              .uniq

      @user.recurring_series.where(fingerprint: old_fingerprints).each do |old_series|
        direction = old_series.direction
        currency  = old_series.currency
        old_fp = old_series.fingerprint
        new_fp = RecurringSeries.fingerprint_for(direction, currency, new_canonical)
        next if old_fp == new_fp

        survivor = @user.recurring_series
                        .where(fingerprint: new_fp)
                        .where.not(id: old_series.id)
                        .first

        if survivor
          # MERGE: re-link members, OR user_confirmed, keep non-null category, max confidence.
          # The survivor's cadence/dates/occurrences_count are intentionally NOT recomputed
          # here — they are re-derived by the immediately-following persist loop in this same
          # run (self-heal), so only the carry-over fields below need to be merged.
          TransactionRecord.where(recurring_series_id: old_series.id)
                           .update_all(recurring_series_id: survivor.id)
          survivor.user_confirmed = survivor.user_confirmed || old_series.user_confirmed
          survivor.category_id  ||= old_series.category_id
          survivor.confidence     = [ survivor.confidence || 0, old_series.confidence || 0 ].max
          survivor.save!
          old_series.destroy!
        else
          # re-point
          old_series.update!(fingerprint: new_fp, canonical_name: new_canonical)
        end
      end
    end
  end

  def reconcile_vanished(detected_series_ids)
    ended = 0
    today = Date.current
    @user.recurring_series.active.find_each do |s|
      next if detected_series_ids.include?(s.id)

      # Lever A cleanup: any still-active "irregular" series is a pre-Lever-A artifact
      # (the detector no longer produces irregular ones) → end it regardless of staleness,
      # unless the user confirmed it. Otherwise such leftovers linger when not yet stale.
      if s.cadence == "irregular" && !s.user_confirmed
        s.update!(status: "ended")
        ended += 1
        next
      end

      next if s.last_seen_on.nil?

      interval = (s.cadence_days || CADENCE_DAYS[s.cadence] || 30).to_i
      grace    = (interval * 1.5).round + 5
      if s.last_seen_on < (today - grace)
        s.update!(status: "ended")
        ended += 1
      end
    end
    ended
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  def median(values)
    sorted = values.sort
    n = sorted.size
    return 0 if n.zero?
    return sorted[n / 2] if n.odd?

    lo = sorted[n / 2 - 1]
    hi = sorted[n / 2]
    if lo.is_a?(Integer) && hi.is_a?(Integer)
      (lo + hi) / 2            # integer median (day deltas): integer division is fine
    else
      (lo + hi) / BigDecimal(2) # decimal amounts: exact BigDecimal halving
    end
  end

  def stddev(values)
    return 0.0 if values.size < 2
    mean = values.sum.to_f / values.size
    var = values.sum { |v| (v - mean)**2 }.to_f / values.size
    Math.sqrt(var)
  end

  def clamp(value, low, high)
    [ [ value, low ].max, high ].min
  end

  def serialize(s)
    {
      id: s.id,
      canonical_name: s.canonical_name,
      merchant_type: s.merchant_type,
      direction: s.direction,
      cadence: s.cadence,
      cadence_days: s.cadence_days,
      expected_amount: s.expected_amount,
      amount_variable: s.amount_variable,
      amount_min: s.amount_min,
      amount_max: s.amount_max,
      currency: s.currency,
      confidence: s.confidence,
      status: s.status,
      user_confirmed: s.user_confirmed,
      occurrences_count: s.occurrences_count,
      first_seen_on: s.first_seen_on,
      last_seen_on: s.last_seen_on,
      next_expected_on: s.next_expected_on
    }
  end
end
