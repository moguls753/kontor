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

    # Fix 2 explosion mitigation — gate LLM canonicalization on RECURRENCE for extracted PayPal
    # sub-merchants. Without this, every one-off PayPal purchase (DB tickets, Eventim, …) would
    # mint a permanent MerchantAlias + burn an LLM call forever. Drop SINGLETON PayPal-extracted
    # keys (row-count < MIN_OCCURRENCES) from the batch; they titleize locally below (canonicals
    # miss → r[:norm_key].titleize fallback). Only keys that ACTUALLY repeat (the OpenAI sub at
    # 3+ occ) reach the LLM and resolve to a brand. Non-PayPal keys are unaffected (a normal
    # singleton merchant still goes to the LLM, as before). Empty-merchant rows already mapped to
    # "PayPal" upstream, so they aggregate and are not dropped.
    paypal_key_counts = rows.each_with_object(Hash.new(0)) do |r, h|
      h[r[:norm_key]] += 1 if r[:paypal_submerchant] && r[:norm_key].present?
    end
    drop_keys = paypal_key_counts.select { |_k, n| n < MIN_OCCURRENCES }.keys.to_set
    norm_keys -= drop_keys.to_a

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

      # A4 (root refactor) — clear-before-relink is now PER-SERIES inside persist_series,
      # NOT a global wipe. WHY: the old global clear detached EVERY member up front, so a
      # series that was no longer re-detected this run (e.g. its canonical changed under
      # Fix 2's PayPal sub-merchant extraction) was left active with 0 members — a "ghost"
      # showing a stale occurrences_count/confidence but "Keine verknüpften Transaktionen"
      # (prod #67). A naive "end memberless active series" patch would regress B4′ (a genuine
      # quarterly/yearly contract whose 3rd charge aged past the 540d LOOKBACK is legitimately
      # active with 0 in-window members and grace MUST keep it). The per-series clear keeps a
      # non-re-detected series' members intact, so reconcile_vanished decides keep-vs-end
      # against REAL data and the ghost cannot form (its members re-point to the new
      # per-merchant series in the SAME run). Atomicity is unchanged: still one outer tx.

      detected_series_ids = Set.new # #3 — key reconcile on SERIES ID, not fingerprint

      # §5.3/§5.4 — partition by [direction, currency], group by [canonical, account, counterpart].
      # account_id is in the key so a series is ACCOUNT-COHERENT on the SOURCE side: a payer's
      # payments on a personal account must NOT merge with the same payer's payments on the joint
      # account. The cross-account merge wrongly pulled a joint-only inflow into the Privat scope (a
      # one-off PayPal payment dragged Katja's whole joint contribution into Privat). With the split,
      # a lone cross-account occurrence forms its own group → too few to build a regular series →
      # stays unmatched, and the scoping (with_member_in) is auto-correct.
      #
      # transfer_counterpart_account_id extends that coherence to the DESTINATION side: a matched
      # transfer to one own account must NOT merge with a same-named, same-amount transfer to a
      # DIFFERENT own account (e.g. a giro→Gemeinschaft "Ansparen" and a giro→TR "Sparplan", both
      # bearing the user's own creditor name). Without it they merged into one series whose members
      # straddle the liquid/investment boundary, and RecurringSeries#flow_bucket (members.any?) then
      # classified the whole series as a transfer, silently dropping the giro→TR liquid outflow from
      # the Liquide forecast lens. Splitting by counterpart aligns the detector, flow_bucket, and
      # in_scope on the same counterpart signal. For merchants the FK is nil (set only by the
      # TransferMatcher for matched internal transfers) → the third key element is a constant nil →
      # merchants STILL group by [canonical, account] only and do NOT over-split on varying IBANs.
      #
      # The fingerprint (direction|currency|canonical, model fingerprint_for) deliberately does NOT
      # include the counterpart, so it is unchanged: existing series still reconcile via
      # where(fingerprint:) + nearest_amount_match. When two counterpart clusters share one
      # fingerprint AND amount, the first claims its row and the @claimed set (persist_series) forces
      # the second to create its own → two series, no double-count, no re-key of existing rows.
      rows.group_by { |r| [ r[:direction], r[:currency] ] }.each do |(direction, currency), part_rows|
        part_rows.group_by { |r| [ r[:canonical], r[:account_id], r[:transfer_counterpart_account_id] ] }.each do |(canonical, _account_id, _cp_id), group_rows|
          # INFLOW purpose sub-grouping (Part-2 regression fix). build_variable_inflow_series lumps
          # ALL of one payer's IBAN-consistent inflows into ONE series, IGNORING the Verwendungszweck.
          # For a SALARY (one purpose, varying amount) that is correct; for a PERSON who sends MANY
          # different recurring payments (Katja: Miete/Strom/Internet/ETF/Ansparen + one-offs) it
          # WRONGLY fuses 5 distinct monthly streams + one-offs into one "20–229" blob. Fix: split an
          # inflow [canonical, account, cp] group by purpose_key(remittance) and run the EXISTING
          # per-group dispatch PER purpose sub-group. SCOPED TO INFLOWS ONLY — outflows/merchants are
          # NOT purpose-split (counterparty name already separates them; merchant remittances are
          # noisy refs → purpose grouping there would over-split). The purpose is NOT in the
          # fingerprint (direction|currency|canonical), so multiple sub-groups sharing one fingerprint
          # still reconcile into separate series via @claimed + nearest_amount_match — the SAME
          # mechanism already used for counterpart clusters above. Downstream of the [canonical,
          # account, cp] grouping, so IBAN/account coherence is untouched; build_variable_inflow_series'
          # own IBAN gate now runs per (payer, purpose) sub-group (still consistent by construction).
          subgroups =
            if direction == "inflow"
              group_rows.group_by { |r| purpose_key(r[:remittance]) }.values
            else
              [ group_rows ] # outflows/merchants UNCHANGED — one group, no purpose split
            end

          subgroups.each do |sub_rows|
            # PART 2 — variable-amount salary path. A salary whose monthly amount VARIES (raises,
            # bonuses, back-pay) is split by amount_subcluster into too-few-per-cluster pieces and
            # never reaches MIN_OCCURRENCES, so it is missed. For an INFLOW group that is
            # counterparty-IBAN-consistent (every row shares ONE non-blank debtor IBAN — so it can
            # never fuse unrelated inflows), bypass amount_subcluster entirely and run a single
            # cadence-primary series over the whole group (micro-outliers dropped, same-month
            # payments collapsed). On success it is the ONLY series for this group; on failure (e.g.
            # n<3 after collapsing) fall through to the normal amount-clustering path below so a
            # fixed-amount inflow still works as before.
            if direction == "inflow" && (salary = build_variable_inflow_series(sub_rows, direction:, currency:, canonical:))
              persisted = persist_series(salary, direction:, currency:, canonical:)
              if persisted
                detected_series_ids << persisted.id
                detected_count += 1
              end
              next
            end

            clusters = amount_subcluster(sub_rows)
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
    # Fix 2 — a PayPal row whose merchant was extracted from the remittance is a SUB-MERCHANT
    # (the single "PayPal Europe" creditor name covers every PayPal debit). Tag it so the LLM
    # batch can be gated on recurrence (explosion mitigation in #detect): a one-off DB/Eventim
    # ticket must NOT become a permanent MerchantAlias/LLM call, while the recurring OpenAI sub
    # (3+ occ) still resolves to its brand.
    # The conduit-leg guard (paypal_conduit_leg?) keeps this flag false for a leg that is
    # already a matched PayPal CONDUIT transfer, mirroring counterparty_raw — such a leg never
    # carries an extracted sub-merchant (it falls back to the junk PayPal Europe name), so it
    # must NOT be tagged as a sub-merchant either (else the LLM explosion-gate would treat it
    # as one).
    paypal_submerchant = !paypal_conduit_leg?(tx, direction) &&
                         paypal_aggregator?(tx, direction) && extract_paypal_merchant(tx).present?
    norm_key = MerchantNormalizer.call(raw)

    # #5 — no name-derived key: keep IBAN-only rows groupable internally via the
    # counterparty IBAN (never sent to the canonicalizer / LLM). Drop only if
    # there is neither a usable name nor an IBAN to group on.
    group_key = norm_key.presence || cp_iban.presence
    return nil if group_key.blank?

    {
      tx_id: tx.id,
      account_id: tx.account_id,
      # FK to the paired own account (set by TransferMatcher for matched internal
      # transfers; nil for merchants). Part of the grouping key so two transfers from the
      # same source to DIFFERENT own accounts don't merge. Raw column read (no association
      # load), mirroring account_id/category_id. NOT counterparty_iban (that's the external
      # bank IBAN text, which varies for Netflix/PayPal and would over-split merchants).
      transfer_counterpart_account_id: tx.transfer_counterpart_account_id,
      amount: tx.amount,
      booking_date: tx.booking_date,
      # Verwendungszweck TEXT carried for INFLOW purpose sub-grouping (purpose_key). Privacy:
      # text only — never amounts — feeds the deterministic normalizer, never the LLM. Read once
      # per candidate; counterparty_raw still reads tx.remittance independently for the norm_key.
      remittance: tx.remittance,
      currency: tx.currency,
      direction:,
      norm_key: norm_key.presence, # nil for IBAN-only rows → excluded from LLM batch
      group_key:,                  # internal grouping fallback (IBAN), never LLM-bound
      counterparty_iban: cp_iban,
      category_id: tx.category_id,
      paypal_submerchant:          # Fix 2 explosion-gate flag (singletons skip the LLM)
    }
  end

  # fallback chain for the LLM norm_key: payee name → other name → remittance token.
  # #5 — a raw IBAN is NEVER returned here (it must not become a norm_key sent to the
  # LLM); IBAN-only rows are grouped internally via build_row's group_key.
  def counterparty_raw(tx, direction)
    primary = direction == "outflow" ? tx.creditor_name : tx.debtor_name
    other   = direction == "outflow" ? tx.debtor_name : tx.creditor_name

    # Fix 2 — payment-aggregator sub-merchant extraction. PayPal books EVERY debit/refund under
    # the single creditor/debtor name "PayPal Europe S.à r.l. et Cie S.C.A.", so the real merchant
    # (OpenAI, DB, Lotto24, …) lives in the remittance. Deriving it BEFORE MerchantNormalizer.call
    # (a) dissolves the €23-coincidence false positive into distinct merchants, (b) surfaces the
    # real recurring OpenAI/ChatGPT sub, and (c) keeps a junk numeric-prefix key from ever reaching
    # the sticky MerchantAlias/LLM. Gate is PayPal-specific (NOT a broad /payments?/i): Amazon
    # Payments Europe is a SEPARATE creditor_name and must keep its own identity. Blank capture →
    # generic "PayPal" (the aggregator name), so empty-merchant/refund rows stay irregular.
    #
    # PART 1 — conduit-leg exception. A PayPal leg that the TransferMatcher already paired as an
    # internal CONDUIT transfer to the user's own PayPal account (transfer_group_id +
    # transfer_counterpart_account_id both set) must NOT have its sub-merchant extracted. WHY:
    # the real EXPENSE lives on the OTHER leg — the genuine "OpenAI Ireland Limited" debit booked
    # on the PayPal account itself (its own series, counted once). Extracting the sub-merchant here
    # would relabel the conduit leg "OpenAI" too and surface a confusing "OpenAI Umbuchung". By
    # skipping extraction, this leg falls back to the normal (junk PayPal Europe) creditor name; it
    # then collapses into one irregular blob that build_series rejects, so the conduit series simply
    # vanishes — no double-count, no relabel. GENUINELY-UNMATCHED PayPal purchases (no transfer
    # link) keep extraction below (preserves the #67 sub-merchant protection).
    if paypal_aggregator?(tx, direction) && !paypal_conduit_leg?(tx, direction)
      return extract_paypal_merchant(tx).presence || "PayPal"
    end

    primary.presence || other.presence ||
      tx.remittance.to_s.split(/\s+/).first.presence
  end

  # Small explicit aggregator gate. Only PayPal this pass: Klarna's layout differs and has no
  # parseable sample, Amazon Payments is its own creditor. Matches the aggregator NAME on the
  # relevant side per direction (creditor for outflow, debtor for inflow — the PP prefix rides
  # on refund inflows too).
  def paypal_aggregator?(tx, direction)
    name = direction == "outflow" ? tx.creditor_name : tx.debtor_name
    name.to_s.match?(/\bpaypal\b/i)
  end

  # PART 1 — true iff this row is a PayPal-aggregator leg that the TransferMatcher ALREADY paired
  # as an internal conduit transfer to an own account (both transfer FKs set). The pipeline order
  # categorize→match→detect guarantees these FKs are populated before detection runs (load_candidates
  # already relies on transfer_group_id). Used by counterparty_raw/build_row to suppress sub-merchant
  # extraction on such legs only (genuinely-unmatched PayPal purchases are untouched).
  def paypal_conduit_leg?(tx, direction)
    paypal_aggregator?(tx, direction) &&
      tx.transfer_group_id.present? &&
      tx.transfer_counterpart_account_id.present?
  end

  # Prefix-anchored merchant extraction from a PayPal remittance. Strips the optional
  # "NNN/" and "PP.<digits>.PP/" (or "<digits>/") reference prefix, then captures up to the
  # FIRST ", Ihr Einkauf bei" (commas INSIDE the name, e.g. "CTS Eventim AG & Co. KGaA", are
  # preserved). Anchoring on the PP separator (not a bare leading dot) avoids over-capturing
  # inside the "PP.6150.PP" token. Locale/direction robust: ", Ihr Einkauf bei" is only the END
  # delimiter; the merchant is the prefix text. Returns nil when nothing matches (→ "PayPal").
  def extract_paypal_merchant(tx)
    r = tx.remittance.to_s
    m = r[/PP\.\d+\.PP\/\.\s*(.*?)\s*,\s*Ihr Einkauf bei/, 1] ||
        r[/\d+\/\.\s*(.*?)\s*,\s*Ihr Einkauf bei/, 1]
    m && m.strip.presence
  end

  # ── INFLOW Verwendungszweck (purpose) normalizer ─────────────────────────────
  # Deterministic purpose_key for INFLOW sub-grouping. RULE = "first significant token, ref-codes
  # kept as a digit-stripped skeleton". Privacy: pure string work on remittance TEXT only — never
  # amounts. Must satisfy BOTH simultaneously:
  #  (A) SPLIT a person's distinct purposes ("Miete"/"Strom"/"Internet"/"ETF Alma"/"Ansparen"/
  #      "Urlaub Mallorca"/"Geldgeschenke Malin" → different keys), so each recurring stream is its
  #      own (payer, purpose) candidate and one-offs stay singletons (n<MIN_OCCURRENCES → no series).
  #  (B) KEEP a salary's VARIED betreff together ("Lohn/Gehalt 2026/01", "Lohn/Gehalt pludoni",
  #      "Lohn/Gehalt 2025/10 und …" → ONE key "lohn/gehalt"), so variable-salary detection is not
  #      re-broken. This is the trap: a naive raw-remittance group would split Pludoni.
  #
  # WHY FIRST token only (NOT first 1–2): "Lohn/Gehalt pludoni" → two-token "lohn/gehalt pludoni"
  # would NOT match "Lohn/Gehalt 2026/01" → "lohn/gehalt", splitting the salary. The one-token rule
  # collapses ALL Pludoni betreff to "lohn/gehalt" ("Lohn/Gehalt" is a single whitespace token — the
  # "/" is internal — so it needs no special handling). That choice is what defuses the trap.
  #
  # Token handling, in order:
  #  - trim only EDGE punctuation, keep internal "/" so "lohn/gehalt" survives intact;
  #  - SKIP a pure number/date/month-year token (0126, 03/2026, 2026/01) — it carries no purpose, so
  #    leading refs don't matter and a trailing date never reaches the key ("Miete 06/2026" == "Miete");
  #  - a MIXED alnum token is a ref code (Kindergeld "KG044007FK074442") → keep its digit-stripped
  #    skeleton ("kgfk") so it is a STABLE non-blank key across months instead of dumping the purpose
  #    into the catch-all blank bucket;
  #  - the first clean ALPHA word is the purpose → return it.
  #  - blank remittance / only numbers+refs → "" (own blank bucket; a lone blank one-off stays n=1).
  def purpose_key(remittance)
    s = remittance.to_s.unicode_normalize(:nfkc).strip.downcase
    return "" if s.empty? # blank remittance → own blank bucket
    s.split(/\s+/).each do |raw|
      tok = raw.gsub(/\A[^a-z0-9\/]+|[^a-z0-9\/]+\z/, "") # trim edge punctuation, keep internal "/"
      next if tok.empty?
      next if tok.match?(/\A\d[\d\/.\-]*\z/) # pure number/date/month-year → no purpose, skip
      if tok.match?(/\d/)                    # mixed alnum REF CODE → digit-stripped skeleton (stable)
        skel = tok.gsub(/\d+/, "")
        return skel if skel.length >= 2
        next
      end
      return tok # first clean alpha word = the purpose
    end
    "" # only numbers/refs found → blank bucket
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

  # ── PART 2 — variable-amount inflow (salary) series ──────────────────────────
  # An inflow-only, counterparty-IBAN-consistent, cadence-primary path for a salary whose amount
  # VARIES month to month. Returns a series hash (same shape as build_series) or nil if the group
  # is not a clean variable-salary candidate (caller then falls back to the normal path).
  #
  # Gating + transforms, in order:
  #  (a) IBAN gate: ALL rows must share one non-blank counterparty (debtor) IBAN. This is the hard
  #      guarantee that the path can NEVER fuse unrelated inflows (different payers have different
  #      IBANs). Without ≥MIN_OCCURRENCES IBAN-consistent rows, bail (→ normal path).
  #  (c) micro-outlier drop: rows whose |amount| is below ~10% of the group median |amount| are
  #      noise (a 4.69 "Nachzahlung" next to ~2000 salary). Drop them so they neither set
  #      expected_amount nor poison cv. (Done BEFORE the month-collapse so a stray micro-row in an
  #      otherwise-empty month can't mint a node.)
  #  (b)/(d) BYPASS amount_subcluster and COLLAPSE multiple payments in the SAME (year,month) into
  #      ONE representative node: amount = MEDIAN of that month's amounts, date = LATEST date in the
  #      month (NOT max amount — avoids inflating the forecast monthly_equiv with a back-pay spike).
  #  (e) run the EXISTING regularity gate (MIN_OCCURRENCES, cadence, cv/share) on the collapsed nodes.
  def build_variable_inflow_series(group_rows, direction:, currency:, canonical:)
    return nil unless direction == "inflow"

    # (a) counterparty-IBAN consistency gate
    ibans = group_rows.map { |r| r[:counterparty_iban].presence }.compact.uniq
    return nil unless ibans.size == 1 && group_rows.all? { |r| r[:counterparty_iban].present? }
    return nil if group_rows.size < MIN_OCCURRENCES

    # (c) drop micro-outliers (< ~10% of group median |amount|)
    group_median_abs = median(group_rows.map { |r| r[:amount].abs })
    floor = group_median_abs * BigDecimal("0.10")
    kept = group_rows.reject { |r| r[:amount].abs < floor }
    return nil if kept.size < MIN_OCCURRENCES

    # (b)/(d) collapse same (year, month) → one node (median amount, latest date), carrying ALL
    # underlying tx_ids/category_ids so every real payment is linked to the series.
    nodes = kept.group_by { |r| [ r[:booking_date].year, r[:booking_date].month ] }.map do |_ym, month_rows|
      {
        amount: median(month_rows.map { |r| r[:amount] }),
        booking_date: month_rows.map { |r| r[:booking_date] }.max,
        member_ids: month_rows.map { |r| r[:tx_id] },
        category_ids: month_rows.map { |r| r[:category_id] }
      }
    end
    return nil if nodes.size < MIN_OCCURRENCES

    nodes.sort_by! { |n| n[:booking_date] }
    dates   = nodes.map { |n| n[:booking_date] }
    amounts = nodes.map { |n| n[:amount] }

    # (e) existing regularity gate, on the collapsed nodes
    deltas = dates.each_cons(2).map { |a, b| (b - a).to_i }
    return nil if deltas.empty?

    med  = median(deltas)
    mean = deltas.sum.to_f / deltas.size
    cv   = mean.zero? ? 0.0 : (stddev(deltas) / mean)

    cadence, bucket_range = classify_cadence(med)
    share = bucket_range ? deltas.count { |d| bucket_range.include?(d) }.to_f / deltas.size : 0.0
    regular = (cv <= CV_MAX) || (share >= BUCKET_SHARE_MIN)
    keep = cadence != "irregular" && regular && med >= MIN_CADENCE_DAYS
    return nil unless keep

    expected_amount = median(amounts)
    min_a = amounts.min
    max_a = amounts.max
    span  = expected_amount.abs.zero? ? 0.0 : (max_a - min_a).abs / expected_amount.abs
    amount_variable = span > AMOUNT_TOLERANCE

    # IBAN-consistent by construction (the gate above) → high-signal confidence input.
    confidence = compute_confidence(occurrences: nodes.size, cv:, amount_variable:, iban_consistent: true)

    last_seen_on  = dates.last
    first_seen_on = dates.first
    anchor_day    = modal_day_of_month(dates)
    next_expected = predict_next(cadence, last_seen_on, anchor_day, med)

    {
      member_ids: nodes.flat_map { |n| n[:member_ids] },
      category_ids: nodes.flat_map { |n| n[:category_ids] },
      cadence:,
      cadence_days: med,
      expected_amount:,
      amount_variable:,
      amount_min: min_a,
      amount_max: max_a,
      confidence:,
      occurrences_count: nodes.size,
      first_seen_on:,
      last_seen_on:,
      next_expected_on: next_expected,
      merchant_type: nil
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

    # Per-series clear-before-relink (root refactor; replaces the old global wipe). Two
    # detaches THEN link, all inside #detect's single outer tx (A4/A7 atomicity intact):
    #   1. drop THIS series' old membership — handles the SHRINK case (a tx that was a member
    #      last run but no longer clusters in; A4 spec 550-562 / stray-member cleanup).
    #   2. detach the incoming members from ANY OTHER series — handles the MOVE-BETWEEN-SERIES
    #      case (a tx that pointed at series A last run now clusters into B).
    # A series NOT re-detected this run is never touched here, so it KEEPS its members and
    # reconcile_vanished judges it against real data (no ghost). The @claimed guard above
    # still forces a second cluster sharing one fingerprint+amount to its own series.
    TransactionRecord.where(recurring_series_id: persisted.id).update_all(recurring_series_id: nil)
    TransactionRecord.where(id: series[:member_ids]).update_all(recurring_series_id: nil)
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
      # P4 — the memberless-DELETE and irregular-cleanup paths only make sense for a series
      # NOT re-detected this run (a re-detected series HAS fresh members and a real cadence),
      # so they stay gated behind `next if detected_series_ids.include?(s.id)`. But the
      # end-grace decision below was ALSO behind that gate, which let a STOPPED series that is
      # still re-detected from stale historical members (≥3 left in the 540d window) linger
      # active forever with a phantom next_expected_on. The grace check now runs for re-detected
      # series too — keyed on last_seen_on being past the grace window, so a series with RECENT
      # members (Spotify-type) is never overdue and stays active.
      unless detected_series_ids.include?(s.id)
        # A series is a derived aggregate of its member transactions. With ZERO live members it
        # represents nothing — there is no history to show and it leaks as a phantom into every
        # scope (a memberless series slips through the scope filter and renders as bogus income).
        # DELETE it outright. The SOLE exception is a user_confirmed series: preserve the user's
        # explicit choice (keep it active, just sync the count to an honest 0). dismissed series
        # never reach here (the iterated scope is .active); their row is retained on purpose to
        # block re-detection by fingerprint.
        if s.transaction_records.empty?
          if s.user_confirmed
            s.update_columns(occurrences_count: 0)
          else
            s.destroy!
            ended += 1
          end
          next
        end

        # From here the series HAS members (real history). Lever A cleanup: a still-active
        # "irregular" leftover is a pre-Lever-A artifact (the detector no longer produces
        # irregular ones) → end it (retaining its members as history) unless the user confirmed it.
        if s.cadence == "irregular" && !s.user_confirmed
          s.update!(status: "ended")
          ended += 1
          next
        end
      end

      next if s.last_seen_on.nil?

      # end-grace (B4′ + P4): a series whose latest charge is past the grace window has stopped
      # recurring → end it (keeps its members as history) UNLESS the user confirmed it. This now
      # also catches a re-detected-but-stopped series (a cancelled salary whose ≥3 historical
      # members still cluster but whose last payment is long past) — auto-ending it instead of
      # leaving it active with a phantom next_expected_on. A user_confirmed stopped series is NOT
      # auto-ended (the user owns that choice; the serializer surfaces it as `overdue` so they can
      # end it manually). An ended series auto-revives via persist_series when its pattern recurs.
      next if s.user_confirmed

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
