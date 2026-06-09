require "rails_helper"

RSpec.describe RecurringDetector do
  let(:user) { create(:user) }
  let(:bc) { create(:bank_connection, user: user) }
  # IBAN nil so own-transfer filtering does not interfere unless a spec opts in
  let(:account) { create(:account, bank_connection: bc, iban: nil) }

  subject { described_class.new(user) }

  # No LLM credential → canonicalizer degrades to deterministic titleize, so the
  # same creditor_name reliably groups WITHOUT hitting the network.
  def charge(name:, amount:, date:, **extra)
    create(:transaction_record, account: account, creditor_name: name,
      amount: amount, booking_date: date, currency: "EUR", **extra)
  end

  def credit(name:, amount:, date:, **extra)
    create(:transaction_record, account: account, creditor_name: nil, debtor_name: name,
      amount: amount, booking_date: date, currency: "EUR", **extra)
  end

  # monthly dates anchored back from today
  def monthly_dates(n, anchor: Date.current - 5)
    (0...n).map { |i| anchor - (i * 30) }
  end

  describe "happy path" do
    it "detects a monthly debit series" do
      monthly_dates(4).each { |d| charge(name: "Spotify", amount: -12.99, date: d) }

      result = subject.detect

      expect(result[:detected]).to eq(1)
      series = user.recurring_series.first
      expect(series.cadence).to eq("monthly")
      expect(series.direction).to eq("outflow")
      expect(series.expected_amount).to eq(-12.99)
      expect(series.occurrences_count).to eq(4)
      expect(series.status).to eq("active")
      expect(TransactionRecord.where(recurring_series_id: series.id).count).to eq(4)
    end

    it "detects a variable-amount utility series" do
      amounts = [ -60.00, -72.00, -55.00, -68.00 ]
      monthly_dates(4).each_with_index { |d, i| charge(name: "Stadtwerke", amount: amounts[i], date: d) }

      subject.detect

      series = user.recurring_series.first
      expect(series).to be_present
      expect(series.amount_variable).to be(true)
    end

    it "detects a monthly credit (inflow) series" do
      monthly_dates(4).each { |d| credit(name: "Arbeitgeber GmbH", amount: 2500.00, date: d) }

      subject.detect

      series = user.recurring_series.inflows.first
      expect(series).to be_present
      expect(series.direction).to eq("inflow")
      expect(series.expected_amount).to eq(2500.00)
      expect(series.expected_amount).to be > 0   # inflow amount sign is positive
      expect(series.occurrences_count).to eq(4)
    end

    it "rates a regular fixed-amount IBAN-consistent series (>=4 occ) as HIGH confidence (recalibrated)" do
      monthly_dates(4).each { |d| charge(name: "EVH", amount: -53.00, date: d, creditor_iban: "DE55000000000000000002") }

      subject.detect

      # recalibrated scoring (divisor 8) → such a series should clear the 0.66 "high" band,
      # not get stuck at "medium" just because there are only 4 months of history.
      expect(user.recurring_series.first.confidence).to be >= 0.66
    end
  end

  describe "rejection rules" do
    it "does not detect a 2-occurrence series (≥3 floor)" do
      monthly_dates(2).each { |d| charge(name: "Spotify", amount: -12.99, date: d) }

      result = subject.detect

      expect(result[:detected]).to eq(0)
      expect(user.recurring_series.count).to eq(0)
    end

    it "does not detect daily sub-weekly habitual spend (coffee)" do
      # daily spacing → median delta 1 < MIN_CADENCE_DAYS; varying amounts also fail
      # the irregular-but-fixed edge allowance → habitual spend dropped.
      amounts = [ -3.50, -4.20, -2.90, -5.10, -3.80, -4.50, -2.75, -5.40, -3.10, -4.95 ]
      amounts.each_with_index { |a, i| charge(name: "Coffee Shop", amount: a, date: Date.current - i) }

      result = subject.detect

      expect(result[:detected]).to eq(0)
    end

    it "does not detect an irregular series even with a fixed amount and ≥4 occurrences (Lever A)" do
      # median delta ~20d → no cadence bucket → irregular. Fixed amount, 5 occurrences:
      # the OLD edge-allowance would have kept this (false positive like train tickets);
      # Lever A drops all irregular series.
      [ 5, 25, 45, 105, 125 ].each { |ago| charge(name: "DB Vertrieb", amount: -3.40, date: Date.current - ago) }

      result = subject.detect

      expect(result[:detected]).to eq(0)
      expect(user.recurring_series.where(canonical_name: "Db Vertrieb")).to be_empty
    end
  end

  # §5b — Lever B (the bidirectional name-heuristic) is GONE. A series is a "transfer" iff
  # its members are matched internal transfers (transfer_group_id, set by the TransferMatcher).
  describe "matched-transfer series = transfer (§5b)" do
    let(:counterpart) { create(:account, bank_connection: bc, role: "giro", role_locked: true) }

    it "flags a series whose members are matched internal transfers, leaving merchants alone" do
      # money moved to an own account: members carry transfer_group_id (matcher already ran)
      monthly_dates(3).each.with_index do |d, i|
        charge(name: "Umbuchung", amount: -500.00, date: d,
          transfer_group_id: "g#{i}", transfer_counterpart_account: counterpart)
      end
      # control: a genuine subscription (no transfer_group_id) stays a normal contract
      monthly_dates(3).each { |d| charge(name: "Spotify", amount: -12.99, date: d) }

      subject.detect

      transfer = user.recurring_series.find_by(canonical_name: "Umbuchung")
      expect(transfer.merchant_type).to eq("transfer")
      expect(user.recurring_series.find_by(canonical_name: "Spotify").merchant_type).not_to eq("transfer")
    end

    it "does not flag a bidirectional name pair when the members are NOT matched transfers" do
      # same counterparty out AND in, but no transfer_group_id → the old Lever B would have
      # flagged this; the new rule must NOT (it is not a corroborated internal transfer).
      monthly_dates(3).each { |d| charge(name: "Eike Rackwitz", amount: -70.00, date: d) }
      monthly_dates(3).each { |d| credit(name: "Eike Rackwitz", amount: 70.00, date: d) }

      subject.detect

      eike = user.recurring_series.where(canonical_name: "Eike Rackwitz")
      expect(eike.pluck(:merchant_type).uniq).to eq([ nil ]) # not flagged transfer
    end

    it "does not override a user-confirmed series" do
      monthly_dates(3).each.with_index do |d, i|
        charge(name: "Umbuchung", amount: -500.00, date: d,
          transfer_group_id: "g#{i}", transfer_counterpart_account: counterpart)
      end
      subject.detect
      confirmed = user.recurring_series.find_by(canonical_name: "Umbuchung")
      confirmed.update!(user_confirmed: true, merchant_type: nil)

      described_class.new(user).detect

      expect(confirmed.reload.merchant_type).to be_nil # user_confirmed not clobbered
    end
  end

  describe "idempotency & stability" do
    it "produces no duplicate rows when run twice" do
      monthly_dates(4).each { |d| charge(name: "Spotify", amount: -12.99, date: d) }

      subject.detect
      expect { described_class.new(user).detect }.not_to change { user.recurring_series.count }
      expect(user.recurring_series.count).to eq(1)
    end

    it "keeps one series across an IBAN change of the counterparty" do
      dates = monthly_dates(4)
      charge(name: "Spotify", amount: -12.99, date: dates[0], creditor_iban: "DE11111111111111111111")
      charge(name: "Spotify", amount: -12.99, date: dates[1], creditor_iban: "DE11111111111111111111")
      charge(name: "Spotify", amount: -12.99, date: dates[2], creditor_iban: "DE22222222222222222222")
      charge(name: "Spotify", amount: -12.99, date: dates[3], creditor_iban: "DE22222222222222222222")

      subject.detect

      expect(user.recurring_series.count).to eq(1)
      series = user.recurring_series.first
      # identity/values: the single series absorbed all 4 occurrences across the IBAN change
      expect(series.canonical_name).to eq("Spotify")
      expect(series.occurrences_count).to eq(4)
      expect(series.expected_amount).to eq(-12.99)
      expect(TransactionRecord.where(recurring_series_id: series.id).count).to eq(4)

      # the same series id survives a second run (stable across the IBAN change)
      original_id = series.id
      described_class.new(user).detect
      expect(user.recurring_series.count).to eq(1)
      expect(user.recurring_series.first.id).to eq(original_id)
    end

    it "extends one series across a price change (band widened)" do
      dates = monthly_dates(6)
      # drift within the §5.3 split gap (gap 1.00 < max(0.15·amt, 0.50)) → one cluster, band extended
      dates[0..2].each { |d| charge(name: "Netflix", amount: -9.99, date: d) }
      dates[3..5].each { |d| charge(name: "Netflix", amount: -10.99, date: d) }

      subject.detect

      expect(user.recurring_series.count).to eq(1)
      series = user.recurring_series.first
      expect(series.amount_min).to eq(-10.99)
      expect(series.amount_max).to eq(-9.99)
    end

    it "keeps two genuine series under one merchant stable across runs (B2′ guard)" do
      # two clearly distinct amount bands (gap > §5.3 split threshold) → two clusters/series
      dates = monthly_dates(4)
      dates.each { |d| charge(name: "Amazon", amount: -8.99, date: d) }
      dates.each { |d| charge(name: "Amazon", amount: -12.99, date: d) }

      subject.detect
      expect(user.recurring_series.count).to eq(2)

      # pin user state on one of them
      pinned = user.recurring_series.order(:expected_amount).first
      pinned.update!(user_confirmed: true)
      pinned_amount = pinned.expected_amount

      2.times { described_class.new(user).detect }

      expect(user.recurring_series.count).to eq(2)
      reloaded = user.recurring_series.find_by(expected_amount: pinned_amount)
      expect(reloaded.id).to eq(pinned.id)
      expect(reloaded.user_confirmed).to be(true)
    end

    # #14 — §5.6 stateful match: a price drift that arrives across TWO separate
    # detect() runs must EXTEND the existing series (widen band, re-median), not
    # spawn a duplicate row. Uses fresh detector instances per run like real callers.
    it "extends one series across a price drift spanning two detect runs (stateful match)" do
      dates = monthly_dates(6)
      dates[3..5].each { |d| charge(name: "Audible", amount: -9.99, date: d) }

      described_class.new(user).detect
      expect(user.recurring_series.count).to eq(1)
      original = user.recurring_series.first
      expect(original.occurrences_count).to eq(3)
      expect(original.amount_min).to eq(-9.99)

      # second run: three more, one euro higher, continuing the monthly cadence
      dates[0..2].each { |d| charge(name: "Audible", amount: -10.99, date: d) }

      described_class.new(user).detect

      expect(user.recurring_series.count).to eq(1)
      series = user.recurring_series.first
      expect(series.id).to eq(original.id)           # SAME row, not a duplicate
      expect(series.occurrences_count).to eq(6)
      expect(series.amount_min).to eq(-10.99)        # band widened down
      expect(series.amount_max).to eq(-9.99)
      expect(series.expected_amount).to eq(-10.49)   # re-medianed across all 6
    end

    # #15 — nearest_amount_match selection + tie-break. Two pre-existing series share
    # the SAME fingerprint at close amounts; a new cluster must extend the NEARER one
    # (min |gap|), and on a gap tie the [gap, id] key picks the LOWER id. At amt~10 the
    # §5.3 split threshold is 0.15·amt = 1.50, so the detector can't create two such
    # close bands organically — seed them directly to isolate the B2′ matcher.
    # detector downcases the canonical inside #fingerprint
    let(:fp_patreon) { Digest::SHA256.hexdigest("outflow|EUR|patreon")[0, 16] }

    it "extends the nearest of two close same-fingerprint series" do
      near = create(:recurring_series, user: user, canonical_name: "Patreon",
        direction: "outflow", currency: "EUR", fingerprint: fp_patreon,
        cadence: "monthly", cadence_days: 30,
        expected_amount: -10.00, amount_min: -10.00, amount_max: -10.00,
        occurrences_count: 3, last_seen_on: Date.current - 400)
      far = create(:recurring_series, user: user, canonical_name: "Patreon",
        direction: "outflow", currency: "EUR", fingerprint: fp_patreon,
        cadence: "monthly", cadence_days: 30,
        expected_amount: -11.00, amount_min: -11.00, amount_max: -11.00,
        occurrences_count: 3, last_seen_on: Date.current - 400)

      # New cluster at -10.30: gap 0.30 to -10.00, gap 0.70 to -11.00 → nearer = -10.00
      monthly_dates(4).each { |d| charge(name: "Patreon", amount: -10.30, date: d) }

      described_class.new(user).detect

      expect(user.recurring_series.count).to eq(2)  # no third row
      near.reload
      far.reload
      expect(near.occurrences_count).to eq(4)       # absorbed the new cluster
      expect(near.amount_min).to eq(-10.30)
      expect(far.occurrences_count).to eq(3)        # untouched
      expect(far.last_seen_on).to eq(Date.current - 400)
    end

    it "tie-breaks equidistant same-fingerprint candidates on the lower id" do
      # Both 0.40 from a -10.40 cluster → gaps tie; min_by [gap, id] picks lower id.
      lower_id = create(:recurring_series, user: user, canonical_name: "Patreon",
        direction: "outflow", currency: "EUR", fingerprint: fp_patreon,
        cadence: "monthly", cadence_days: 30,
        expected_amount: -10.00, amount_min: -10.00, amount_max: -10.00,
        occurrences_count: 3, last_seen_on: Date.current - 400)
      higher_id = create(:recurring_series, user: user, canonical_name: "Patreon",
        direction: "outflow", currency: "EUR", fingerprint: fp_patreon,
        cadence: "monthly", cadence_days: 30,
        expected_amount: -10.80, amount_min: -10.80, amount_max: -10.80,
        occurrences_count: 3, last_seen_on: Date.current - 400)
      expect(lower_id.id).to be < higher_id.id

      monthly_dates(4).each { |d| charge(name: "Patreon", amount: -10.40, date: d) }

      described_class.new(user).detect

      expect(user.recurring_series.count).to eq(2)
      lower_id.reload
      higher_id.reload
      expect(lower_id.occurrences_count).to eq(4)   # lower id won the tie
      expect(higher_id.occurrences_count).to eq(3)  # untouched
    end
  end

  describe "yearly cadence" do
    # happy path: ≥3 charges ~365d apart → 'yearly' with a sane next_expected_on,
    # and no crash when last_seen lands on a leap day.
    #
    # 3 yearly occurrences span ~730d, beyond the 540d production lookback (a
    # documented v1 gap, PLAN §"Annual subscriptions"). Widen the window for THIS
    # test so the yearly classification + leap-safe predict_next are exercised E2E.
    it "detects a yearly series with a leap-safe next_expected_on" do
      stub_const("RecurringDetector::LOOKBACK_DAYS", 1800)
      # last_seen on Feb 29 forces predict_next's next_year to clamp, not raise.
      dates = [ Date.new(2024, 2, 29), Date.new(2023, 3, 1), Date.new(2022, 3, 1) ]
      dates.each { |d| charge(name: "Annual Insurance", amount: -240.00, date: d) }

      described_class.new(user).detect

      series = user.recurring_series.first
      expect(series).to be_present
      expect(series.cadence).to eq("yearly")
      expect(series.occurrences_count).to eq(3)
      expect(series.last_seen_on).to eq(Date.new(2024, 2, 29))
      expect(series.next_expected_on).to be_a(Date)            # no leap-boundary crash
      expect(series.next_expected_on).to be > series.last_seen_on
    end
  end

  describe "own-account transfers" do
    it "excludes a transfer whose counterparty IBAN is the user's own account IBAN (S3)" do
      own = create(:account, bank_connection: bc, iban: "DE89370400440532013000")
      monthly_dates(4).each do |d|
        create(:transaction_record, account: account, creditor_name: "Sparkonto",
          creditor_iban: own.iban, amount: -500.00, booking_date: d, currency: "EUR")
      end

      # positive control: a genuine (non-transfer) merchant series in the SAME run
      # must STILL be detected — proves the S3 filter is surgical, not a blanket drop.
      monthly_dates(4).each { |d| charge(name: "Spotify", amount: -12.99, date: d) }

      result = subject.detect

      expect(result[:detected]).to eq(1)
      expect(user.recurring_series.count).to eq(1)
      series = user.recurring_series.first
      expect(series.canonical_name).to eq("Spotify")            # the merchant, not the transfer
      expect(series.expected_amount).to eq(-12.99)
      # the own-account transfer never became a series
      expect(user.recurring_series.where(canonical_name: "Sparkonto")).to be_empty
    end

    # NULL-safe SQL filter guard: when own_ibans is present, the self-transfer (its
    # counterparty IBAN ∈ user's accounts) is excluded, BUT a normal tx whose
    # counterparty IBAN is NULL is NOT swept up by the `NOT IN` (SQLite NULL trap) and
    # still forms a series in the same run.
    it "excludes a self-transfer while keeping NULL-counterparty-IBAN rows (NULL-safe filter)" do
      own = create(:account, bank_connection: bc, iban: "DE89370400440532013000")
      # self-transfer → excluded
      monthly_dates(4).each do |d|
        create(:transaction_record, account: account, creditor_name: "Sparkonto",
          creditor_iban: own.iban, amount: -500.00, booking_date: d, currency: "EUR")
      end
      # normal merchant, counterparty IBAN NULL → must survive the NOT IN filter
      monthly_dates(4).each do |d|
        create(:transaction_record, account: account, creditor_name: "Spotify",
          creditor_iban: nil, amount: -12.99, booking_date: d, currency: "EUR")
      end

      subject.detect

      expect(user.recurring_series.count).to eq(1)
      series = user.recurring_series.first
      expect(series.canonical_name).to eq("Spotify")
      expect(series.occurrences_count).to eq(4)
      expect(user.recurring_series.where(canonical_name: "Sparkonto")).to be_empty
    end

    # Regression: real Enable-Banking data sets the SELF-side IBAN (debtor_iban on an
    # outflow) to the user's OWN account IBAN. The S3 filter must check only the
    # COUNTERPARTY side, so a normal merchant outflow is kept even though its debtor_iban
    # ∈ own_ibans. (A both-sides predicate would silently drop every booked outflow.)
    it "keeps a merchant outflow whose self-side debtor_iban is the user's own account IBAN" do
      own_iban = "DE89370400440532013000"
      create(:account, bank_connection: bc, iban: own_iban)
      monthly_dates(4).each do |d|
        create(:transaction_record, account: account, creditor_name: "Spotify",
          creditor_iban: "DE55555555555555555555", debtor_iban: own_iban,
          amount: -12.99, booking_date: d, currency: "EUR")
      end

      subject.detect

      expect(user.recurring_series.count).to eq(1)
      expect(user.recurring_series.first.canonical_name).to eq("Spotify")
      expect(user.recurring_series.first.occurrences_count).to eq(4)
    end

    # Regression (prod 2026-06-09): once the account IBANs are populated, own_ibans is
    # non-empty and S3 fires. A MATCHED internal transfer (transfer_group_id set by the
    # matcher) has its counterparty IBAN ∈ own_ibans — but it must STILL be detected so
    # §5b/flow_bucket can place it in the Sparen/Transfer Topf. Only the transfer_group_id
    # IS NULL guard keeps it alive; without it the Sparen-Topf silently empties.
    it "keeps a MATCHED own-account transfer (transfer_group_id set) so flow_bucket can place it" do
      own = create(:account, bank_connection: bc, iban: "DE89370400440532013000")
      monthly_dates(4).each.with_index do |d, i|
        create(:transaction_record, account: account, creditor_name: "Ansparen",
          creditor_iban: own.iban, amount: -70.00, booking_date: d, currency: "EUR",
          transfer_group_id: "grp-#{i}", transfer_counterpart_account: own)
      end

      subject.detect

      series = user.recurring_series.find_by(canonical_name: "Ansparen")
      expect(series).to be_present
      expect(series.occurrences_count).to eq(4)
      expect(series.merchant_type).to eq("transfer") # §5b flags it
    end
  end

  describe "user-state preservation" do
    it "does not resurrect a dismissed series with a matching fingerprint" do
      fp = Digest::SHA256.hexdigest("outflow|EUR|spotify")[0, 16]
      dismissed = create(:recurring_series, user: user, canonical_name: "Spotify",
        direction: "outflow", currency: "EUR", fingerprint: fp,
        expected_amount: -12.99, amount_min: -12.99, amount_max: -12.99, status: "dismissed")

      monthly_dates(4).each { |d| charge(name: "Spotify", amount: -12.99, date: d) }

      subject.detect

      expect(dismissed.reload.status).to eq("dismissed")
      expect(TransactionRecord.where(recurring_series_id: dismissed.id).count).to eq(0)
    end

    it "clears a stale link when a tx drops out of a series (A4)" do
      monthly_dates(4).each { |d| charge(name: "Spotify", amount: -12.99, date: d) }
      subject.detect
      series = user.recurring_series.first

      # attach an unrelated tx as a stale member, then re-run
      stray = charge(name: "Unrelated One-Off", amount: -7.77, date: Date.current - 2)
      stray.update!(recurring_series_id: series.id)

      described_class.new(user).detect

      expect(stray.reload.recurring_series_id).to be_nil
    end
  end

  describe "end-grace reconciliation (B4′)" do
    it "keeps an active series whose latest charge is within cadence*1.5+grace" do
      series = create(:recurring_series, :monthly, user: user, status: "active",
        canonical_name: "Old Sub", last_seen_on: Date.current - 20, cadence_days: 30)

      described_class.new(user).detect

      expect(series.reload.status).to eq("active")
    end

    it "ends an active series whose latest charge is far past the grace window" do
      series = create(:recurring_series, :monthly, user: user, status: "active",
        canonical_name: "Dead Sub", last_seen_on: Date.current - 120, cadence_days: 30)

      described_class.new(user).detect

      expect(series.reload.status).to eq("ended")
    end

    it "ends a still-active 'irregular' leftover even when not stale (Lever A cleanup), but keeps a confirmed one" do
      leftover = create(:recurring_series, user: user, status: "active", cadence: "irregular",
        canonical_name: "Old Irregular", last_seen_on: Date.current - 10, cadence_days: 20)
      confirmed = create(:recurring_series, user: user, status: "active", cadence: "irregular",
        canonical_name: "Kept Irregular", last_seen_on: Date.current - 10, cadence_days: 20, user_confirmed: true)

      described_class.new(user).detect

      expect(leftover.reload.status).to eq("ended")     # pre-Lever-A artifact swept
      expect(confirmed.reload.status).to eq("active")   # user_confirmed protected
    end
  end

  describe "canonical upgrade reconciliation" do
    let!(:credential) { create(:llm_credential, user: user) }

    def stub_llm(rows)
      body = { choices: [ { message: { content: rows.to_json } } ] }
      response = instance_double(Net::HTTPResponse, code: "200", body: body.to_json)
      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:post).and_return(response)
      http
    end

    it "re-points a series and preserves user_confirmed (S2)" do
      # deterministic alias keys the existing series
      create(:merchant_alias, user: user, raw_key: "spotify", canonical_name: "Spotify", source: "deterministic", merchant_type: nil)
      fp = Digest::SHA256.hexdigest("outflow|EUR|spotify")[0, 16]
      series = create(:recurring_series, user: user, canonical_name: "Spotify",
        direction: "outflow", currency: "EUR", fingerprint: fp,
        expected_amount: -12.99, amount_min: -12.99, amount_max: -12.99, user_confirmed: true)

      monthly_dates(4).each { |d| charge(name: "spotify", amount: -12.99, date: d) }
      # LLM upgrades "spotify" → "Spotify AB"
      stub_llm([ { raw: "spotify", canonical: "Spotify AB", type: "subscription" } ])

      described_class.new(user).detect

      series.reload
      expect(series.canonical_name).to eq("Spotify AB")
      new_fp = Digest::SHA256.hexdigest("outflow|EUR|spotify ab")[0, 16]
      expect(series.fingerprint).to eq(new_fp)
      expect(series.user_confirmed).to be(true)
    end

    # #9 — model-level rename-recompute: renaming canonical_name on the model resyncs
    # the fingerprint to fingerprint_for(direction, currency, new_name) via before_save.
    it "recomputes the fingerprint on a model rename" do
      series = create(:recurring_series, user: user, canonical_name: "Spotify",
        direction: "outflow", currency: "EUR")
      old_fp = series.fingerprint

      series.update!(canonical_name: "Spotify AB")

      expect(series.fingerprint).to eq(
        RecurringSeries.fingerprint_for("outflow", "EUR", "Spotify AB")
      )
      expect(series.fingerprint).not_to eq(old_fp)
    end

    # #9 — end-to-end: a user-RENAMED series (its fingerprint moved with the rename)
    # is still found + re-pointed by a canonical upgrade via FINGERPRINT, not by a
    # name-keyed lookup. No duplicate is spawned on the next detect.
    it "re-points a renamed series by fingerprint without creating a duplicate" do
      create(:merchant_alias, user: user, raw_key: "spotify", canonical_name: "Spotify Old", source: "deterministic", merchant_type: nil)

      # the user renamed this series to "Spotify Old"; the before_save resynced its
      # fingerprint to fingerprint_for(outflow, EUR, "Spotify Old").
      series = create(:recurring_series, user: user, canonical_name: "Spotify Old",
        direction: "outflow", currency: "EUR",
        expected_amount: -12.99, amount_min: -12.99, amount_max: -12.99, user_confirmed: true)
      expect(series.fingerprint).to eq(RecurringSeries.fingerprint_for("outflow", "EUR", "Spotify Old"))

      monthly_dates(4).each { |d| charge(name: "spotify", amount: -12.99, date: d) }
      # LLM upgrades the alias "Spotify Old" → "Spotify New"
      stub_llm([ { raw: "spotify", canonical: "Spotify New", type: "subscription" } ])

      described_class.new(user).detect

      # exactly one series — re-pointed, not duplicated
      expect(user.recurring_series.count).to eq(1)
      series.reload
      expect(series.canonical_name).to eq("Spotify New")
      expect(series.fingerprint).to eq(RecurringSeries.fingerprint_for("outflow", "EUR", "Spotify New"))
      expect(series.user_confirmed).to be(true)
    end

    it "merges two aliases that upgrade to the same canonical (B3′)" do
      create(:merchant_alias, user: user, raw_key: "spotify", canonical_name: "Spotify", source: "deterministic", merchant_type: nil)
      create(:merchant_alias, user: user, raw_key: "spotify ab", canonical_name: "Spotify Ab", source: "deterministic", merchant_type: nil)

      fp_a = Digest::SHA256.hexdigest("outflow|EUR|spotify")[0, 16]
      fp_b = Digest::SHA256.hexdigest("outflow|EUR|spotify ab")[0, 16]
      cat = create(:category, user: user)
      s_a = create(:recurring_series, user: user, canonical_name: "Spotify",
        direction: "outflow", currency: "EUR", fingerprint: fp_a,
        expected_amount: -12.99, amount_min: -12.99, amount_max: -12.99, user_confirmed: true)
      s_b = create(:recurring_series, user: user, canonical_name: "Spotify Ab",
        direction: "outflow", currency: "EUR", fingerprint: fp_b,
        expected_amount: -12.99, amount_min: -12.99, amount_max: -12.99, category: cat)

      # both upgrade to canonical "Spotify"
      stub_llm([
        { raw: "spotify", canonical: "Spotify", type: "subscription" },
        { raw: "spotify ab", canonical: "Spotify", type: "subscription" }
      ])

      # seed some tx so resolve() is exercised on both keys
      monthly_dates(4).each { |d| charge(name: "spotify", amount: -12.99, date: d) }
      monthly_dates(4).each { |d| charge(name: "spotify ab", amount: -12.99, date: d) }

      described_class.new(user).detect

      survivors = user.recurring_series.where(fingerprint: Digest::SHA256.hexdigest("outflow|EUR|spotify")[0, 16])
      expect(survivors.count).to eq(1)
      survivor = survivors.first
      expect(survivor.user_confirmed).to be(true)
      expect(survivor.category_id).to eq(cat.id)
      expect(RecurringSeries.exists?(s_b.id)).to be(false) if s_b.id != survivor.id
    end
  end
end
