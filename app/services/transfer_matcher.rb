require "securerandom"
require "set"

# Pairs the two legs of a movement between the user's OWN accounts (−X on A,
# +X on B≠A) into a single internal transfer: both legs get a shared
# transfer_group_id and a transfer_counterpart_account_id pointing at the other
# leg's account. A matched transfer is net-zero for net worth and drops out of
# income/expenses (§4).
#
# B1 — amount + date is NOT enough. Pairing every −X outflow with any +X inflow
# on another own account would, at round amounts (70/100/500), happily pair
# UNRELATED transactions (a real −70 expense + Katja's coincidental +70 income)
# and make a real expense AND a real income vanish. So a counterparty
# corroboration is MANDATORY:
#   (a) the counterpart IBAN on a leg is one of the user's own account IBANs, OR
#   (b) BOTH legs name the SAME counterparty AND that name is one of the user's
#       own account-holder names (derived, not just "equal across the two legs":
#       a −50/+50 Amazon expense+refund names "Amazon" on both legs but Amazon is
#       not an own holder, so it must NOT pair).
# Remittance hints ("Umbuchung"/"Übertrag") are NOT a standalone signal — at
# round amounts a lone "Umbuchung" outflow would pair with an unrelated salary
# inflow. A hint only counts when it appears on BOTH legs (both sides agree this
# is an internal move). Plain amount+date is never auto-matched.
#
# Idempotent and additive: already-matched legs are skipped; re-runs only pair
# new legs. S2: a leg whose transfer_group_id is set but whose
# transfer_counterpart_account_id is NULL (the counterpart account was deleted →
# FK nullified the column) is un-matched, so the surviving leg counts as a flow
# again.
#
# PayPal conduit (standard double-entry model — Firefly III / QuickBooks):
# PayPal is an ASSET account the user funds and withdraws from, so a bank↔PayPal
# flow is a TRANSFER, not a flow. But unlike a normal own-account transfer it is
# ONE-LEGGED and SAME-SIGN: the giro Lastschrift (−X, "PayPal Europe S.à r.l.")
# funds the wallet, yet PayPal NEVER books a matching +X (it doesn't record the
# funding-in). pair_new_legs only ever pairs a −X with a +X on another account,
# so this lone debit never enters a pair → it counts as an expense ALONGSIDE the
# real PayPal purchase = double-count. mark_paypal_conduit_legs fixes this: it
# classifies a giro leg facing PayPal Europe as a transfer to the user's PayPal
# account by COUNTERPARTY (not by 1:1 amount matching — funding is batched and
# FX'd, so amounts never line up), setting transfer_counterpart_account_id =
# the PayPal account. in_scope/flow_bucket then net it (§4a keys on that FK, not
# on group cardinality), so it stops counting and drops out of the list.
#
# ⚠️ TRADE-OFF (accepted): netting is by-counterparty with no offsetting expense
# required. If a bank-funded PayPal payment's purchase is NOT on the PayPal account
# (guest/express checkout, a scraper gap, or giro history predating PayPal data),
# the funding leg is netted but no purchase carries the spend → that expense
# silently UNDERcounts. Inherent to the Firefly-style model + scrape completeness;
# spot-check after the first re-run (Σ marked giro→PayPal ≈ Σ PayPal outflows).
class TransferMatcher
  # Booking lag between two accounts: real bookings run 0–3 days apart; the user's
  # own data lands same-day. ±4 days is the safe window (§7).
  WINDOW_DAYS = 4

  # Remittance tokens that corroborate an internal move (tertiary, weak signal).
  TRANSFER_HINTS = /\b(umbuchung|übertrag|uebertrag|transfer|eigenübertrag)\b/i

  # PayPal Europe S.à r.l.'s SEPA collection IBAN ends in "200E" (e.g.
  # LU89751000135104200E). It is the counterparty on every funding Lastschrift /
  # withdrawal credit — stable and language-independent, so the PRIMARY signal.
  PAYPAL_IBAN_SUFFIX = "200E"
  # Fallback for rows missing the counterpart IBAN: the counterparty name. Tolerates
  # the canonical legal form "PayPal (Europe) S.à r.l. …" (parenthesised) as well as
  # "PayPal Europe", but stays specific (a bare "paypal" never matches) so a normal
  # merchant is never reclassified.
  PAYPAL_NAME = /paypal\b.{0,3}\beurope/i

  def initialize(user)
    @user = user
  end

  def match
    TransactionRecord.transaction do
      unmatch_orphaned_legs
      pair_new_legs
      mark_paypal_conduit_legs
    end
  end

  private

  # Own account IBANs — same source the recurring detector uses
  # (recurring_detector.rb:111). Lower-cased for case-insensitive comparison.
  def own_ibans
    @own_ibans ||= @user.accounts.pluck(:iban).compact.map { |i| i.downcase.gsub(/\s+/, "") }.to_set
  end

  # The user's own account-holder names. A name alone ("Amazon") being equal on
  # both legs proves nothing — a −50/+50 Amazon expense+refund collides. So the
  # name path is only trusted when the matched name is one the user actually owns.
  # Two grounded sources, both verifiable from the user's own data:
  #   • each account's display name (the label the user assigned, e.g. their name);
  #   • the counterparty name on any leg whose counterpart IBAN is a KNOWN OWN
  #     IBAN — that leg is a verified own-account move, so its counterparty is the
  #     own holder (banks the holder name for IBAN-less accounts, e.g. TR).
  def own_holder_names
    @own_holder_names ||= begin
      names = @user.accounts.pluck(:name).map { |n| normalize_name(n) }

      legs.each do |t|
        if t.amount.negative? && normalize_iban(t.creditor_iban).then { |i| i && own_ibans.include?(i) }
          names << normalize_name(t.creditor_name)
        elsif t.amount.positive? && normalize_iban(t.debtor_iban).then { |i| i && own_ibans.include?(i) }
          names << normalize_name(t.debtor_name)
        end
      end

      names.compact.reject(&:blank?).to_set
    end
  end

  # S2 — a leg with a transfer_group_id but no transfer_counterpart_account_id
  # means the counterpart account was deleted (FK on_delete: :nullify). The
  # pairing is broken, so drop the group_id: the surviving leg becomes a normal
  # flow again rather than a stale match that counts as a transfer forever.
  def unmatch_orphaned_legs
    legs.select { |t| t.transfer_group_id.present? && t.transfer_counterpart_account_id.nil? }
        .each { |t| t.update!(transfer_group_id: nil) }
  end

  # Deterministic greedy pairing (S1): walk outflows ordered by id; for each,
  # pick the nearest-by-date unclaimed corroborated inflow (tie-break: lowest id).
  # A @claimed set prevents any inflow being used twice, so two equal amounts on
  # the same day pair cleanly 1:1 instead of crossing over.
  #
  # Finding 7 — pre-bucket inflows by [currency, -amount] so each outflow scans
  # only the handful of inflows that could possibly match it (same currency, the
  # exact opposite amount) instead of every inflow. Turns O(outflows×inflows) into
  # O(outflows × bucket-size); the date window + corroboration run on those few.
  def pair_new_legs
    claimed = Set.new
    candidates = legs.reject(&:internal_transfer?)

    outflows = candidates.select { |t| t.amount.negative? }.sort_by(&:id)
    inflow_buckets = candidates.select { |t| t.amount.positive? }
                               .group_by { |t| [ t.currency, t.amount ] }

    outflows.each do |out|
      bucket = inflow_buckets[[ out.currency, -out.amount ]]
      next if bucket.blank?

      match = best_inflow_for(out, bucket, claimed)
      next unless match

      claimed << match.id
      group_id = SecureRandom.uuid
      out.update!(transfer_group_id: group_id, transfer_counterpart_account_id: match.account_id)
      match.update!(transfer_group_id: group_id, transfer_counterpart_account_id: out.account_id)
    end
  end

  # PayPal conduit (one-legged, both directions, idempotent). For each leg that is
  # NOT on the PayPal account and is not already a transfer, if its counterparty
  # (by sign: creditor on a debit/funding, debtor on a credit/withdrawal) is
  # PayPal Europe, mark it as a transfer TO the PayPal account. There is no second
  # leg to share a group with, so we mint a fresh per-leg group_id; in_scope and
  # flow_bucket read only transfer_counterpart_account_id, so a lone leg suffices.
  #
  # Guards: a no-op unless the user actually HAS a PayPal account (a one-off "pay
  # via PayPal" without a wallet stays a real expense); never touches PayPal's own
  # purchase/income rows; skips already-matched legs (internal_transfer?) so a
  # re-run keeps the same group_id and the +/− matcher's real transfers are left
  # alone. Runs AFTER pair_new_legs so a genuine two-leg transfer is claimed first
  # (defensive — PayPal books no funding +X, so they never actually collide).
  def mark_paypal_conduit_legs
    return unless paypal_account_id

    legs.each do |t|
      next if t.account_id == paypal_account_id
      next if t.internal_transfer?
      next unless paypal_counterparty?(t)

      t.update!(
        transfer_group_id: SecureRandom.uuid,
        transfer_counterpart_account_id: paypal_account_id
      )
    end
  end

  # The single PayPal account's id, identified by its bank_connection provider
  # (the typed enum set at connect time) — NOT the renameable name or the inferred
  # role. Memoized so the join runs once, not per-leg. nil ⇒ no PayPal account ⇒
  # the whole conduit pass is inert.
  def paypal_account_id
    return @paypal_account_id if defined?(@paypal_account_id)

    @paypal_account_id = @user.accounts.joins(:bank_connection)
                              .where(bank_connections: { provider: "paypal" })
                              .pick(:id)
  end

  # True when this giro leg's counterparty is PayPal Europe. By sign: a debit
  # (funding) names PayPal as the CREDITOR; a credit (withdrawal) names it as the
  # DEBTOR. Match the counterpart IBAN ending "200E" (primary) or the counterpart
  # name "PayPal Europe" (fallback for IBAN-less rows).
  def paypal_counterparty?(t)
    debit = t.amount.negative?
    cp_iban = normalize_iban(debit ? t.creditor_iban : t.debtor_iban)
    # IBAN is authoritative when present: a row carrying a counterpart IBAN is PayPal
    # only if that IBAN is the "200E" collection account. A different IBAN with a
    # "PayPal …" name (a PayPal-branded service fee / card settlement) is NOT a wallet
    # top-up and must stay a real flow. Fall back to the name ONLY for IBAN-less rows.
    return cp_iban.upcase.end_with?(PAYPAL_IBAN_SUFFIX) if cp_iban.present?

    (debit ? t.creditor_name : t.debtor_name).to_s.match?(PAYPAL_NAME)
  end

  # `bucket` is already filtered to the same currency and the exact opposite
  # amount; only the date window and corroboration remain to check.
  def best_inflow_for(out, bucket, claimed)
    eligible = bucket.select do |inn|
      !claimed.include?(inn.id) &&
        inn.account_id != out.account_id &&
        within_window?(out.booking_date, inn.booking_date) &&
        corroborated?(out, inn)
    end
    return nil if eligible.empty?

    eligible.min_by { |inn| [ (inn.booking_date - out.booking_date).to_i.abs, inn.id ] }
  end

  def within_window?(date_a, date_b)
    (date_a - date_b).to_i.abs <= WINDOW_DAYS
  end

  # B1 — at least one counterparty corroboration must hold.
  def corroborated?(out, inn)
    iban_corroborates?(out, inn) ||
      name_corroborates?(out, inn) ||
      remittance_corroborates?(out, inn)
  end

  # (a) Strongest: the counterpart IBAN on either leg is one of the user's own
  # account IBANs. On an outflow the counterpart is the creditor; on an inflow the
  # debtor. Greatest signal for IBAN-bearing accounts (Tomorrow).
  def iban_corroborates?(out, inn)
    return false if own_ibans.empty?

    normalize_iban(out.creditor_iban).then { |i| own_ibans.include?(i) if i } ||
      normalize_iban(inn.debtor_iban).then { |i| own_ibans.include?(i) if i } || false
  end

  # (b) Same account holder on both legs (Eike↔Eike) — fallback for IBAN-less
  # legs (Trade Republic). The outflow's creditor (the payee) must equal the
  # inflow's debtor (the payer) AND that name must be one the user actually OWNS
  # (own_holder_names). Bare cross-leg equality is not enough: a −50/+50 "Amazon"
  # expense+refund names "Amazon" on both legs but Amazon is not an own holder, so
  # it must not pair (finding 8).
  def name_corroborates?(out, inn)
    payee = normalize_name(out.creditor_name)
    payer = normalize_name(inn.debtor_name)
    return false if payee.blank? || payer.blank?

    payee == payer && own_holder_names.include?(payee)
  end

  # (c) Weak tertiary: a transfer hint ("Umbuchung"/"Übertrag"/…) must appear on
  # BOTH legs — both sides independently mark this as an internal move. A lone
  # "Umbuchung" outflow is NOT enough (it would pair with an unrelated salary
  # inflow of the same amount); the inflow must agree (finding 7/blocker 2).
  def remittance_corroborates?(out, inn)
    TRANSFER_HINTS.match?(out.remittance.to_s) && TRANSFER_HINTS.match?(inn.remittance.to_s)
  end

  def normalize_iban(iban)
    iban.presence&.downcase&.gsub(/\s+/, "")
  end

  def normalize_name(name)
    name.presence&.downcase&.strip&.gsub(/\s+/, " ")
  end

  # All booked legs for the user. Loaded once per run; pairing/unmatching mutate
  # in memory-tracked rows but always read from this single batch.
  def legs
    @legs ||= @user.transaction_records.booked.to_a
  end
end
