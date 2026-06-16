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

  describe "outlier rescue (one-off within a recurring amount band)" do
    it "still detects the recurring fixed amount and excludes a one-off to the same payee" do
      # monthly rent at a fixed amount …
      monthly_dates(3).each { |d| charge(name: "Eike Rackwitz", amount: -445.00, date: d) }
      # … plus a single one-off to the SAME payee, within 15% of the rent (≈12% over 445)
      charge(name: "Eike Rackwitz", amount: -498.76, date: Date.current - 5)

      subject.detect

      expect(user.recurring_series.outflows.count).to eq(1)
      rent = user.recurring_series.outflows.first
      expect(rent.cadence).to eq("monthly")
      expect(rent.expected_amount).to eq(-445.00)
      expect(rent.occurrences_count).to eq(3)
      # the one-off is NOT folded into the series
      expect(TransactionRecord.where(recurring_series_id: rent.id).count).to eq(3)
    end
  end

  describe "account-coherent series (no cross-account merge)" do
    it "does not merge a one-off on a personal account into the same payee's joint-account series" do
      joint = create(:account, bank_connection: bc, iban: nil, shared: true)
      # Katja's monthly contribution lands on the JOINT account (3 occurrences) …
      [ Date.current - 5, Date.current - 35, Date.current - 65 ].each do |d|
        create(:transaction_record, account: joint, creditor_name: nil, debtor_name: "Katja Stumpf",
          amount: 70.00, booking_date: d, currency: "EUR")
      end
      # … plus ONE same-payee occurrence on a PERSONAL account, monthly-aligned + within the
      # amount band — WITHOUT account-coherence it would fold into a single 4-member series
      # spanning both accounts, which then leaks the joint flow into the Privat scope.
      credit(name: "Katja Stumpf", amount: 72.00, date: Date.current - 95)

      subject.detect

      series = user.recurring_series.find_by(canonical_name: "Katja Stumpf")
      expect(series).to be_present
      # account-coherent: every member is on the joint account …
      expect(TransactionRecord.where(recurring_series_id: series.id).distinct.pluck(:account_id)).to eq([ joint.id ])
      # … and the lone personal occurrence never joined a series (too few to recur alone).
      personal = TransactionRecord.find_by(account_id: account.id, debtor_name: "Katja Stumpf")
      expect(personal.recurring_series_id).to be_nil
    end
  end

  describe "counterpart-coherent transfers (no cross-destination merge)" do
    it "splits same-name, same-amount transfers to different own accounts into two series" do
      # Two destinations for the SAME source ("account"), SAME canonical name, SAME monthly
      # amount, but DIFFERENT transfer_counterpart_account → must NOT merge into one straddling
      # series. iban: nil on both so own_ibans stays empty and the S3 filter is inert.
      gemein = create(:account, bank_connection: bc, iban: nil, role: "giro", role_locked: true)
      invest = create(:account, bank_connection: bc, iban: nil, role: "investment", role_locked: true)

      # giro → Gemeinschaft "Eike Rackwitz" €70/mo (matched transfer)
      monthly_dates(4).each.with_index do |d, i|
        charge(name: "Eike Rackwitz", amount: -70.00, date: d,
          transfer_group_id: "gem-#{i}", transfer_counterpart_account: gemein)
      end
      # giro → investment "Eike Rackwitz" €70/mo (matched transfer, different destination)
      monthly_dates(4).each.with_index do |d, i|
        charge(name: "Eike Rackwitz", amount: -70.00, date: d,
          transfer_group_id: "inv-#{i}", transfer_counterpart_account: invest)
      end
      # control: a plain merchant (nil counterpart) must stay ONE intact series
      monthly_dates(4).each { |d| charge(name: "Spotify", amount: -9.99, date: d) }

      subject.detect

      # the two transfers no longer straddle: two DISTINCT destination-coherent series
      transfers = user.recurring_series.where(canonical_name: "Eike Rackwitz")
      expect(transfers.count).to eq(2)
      counterparts = transfers.map do |s|
        TransactionRecord.where(recurring_series_id: s.id).distinct.pluck(:transfer_counterpart_account_id)
      end
      # each series is keyed to exactly one counterpart (no straddle), together covering both
      expect(counterparts).to contain_exactly([ gemein.id ], [ invest.id ])
      # each is a clean 4-member transfer series (no double-count)
      expect(transfers.map(&:occurrences_count)).to contain_exactly(4, 4)
      transfers.each { |s| expect(s.flow_bucket).to eq("transfer") }

      # merchants do NOT over-split: the nil-counterpart series is one intact expense series
      spotify = user.recurring_series.find_by(canonical_name: "Spotify")
      expect(spotify.occurrences_count).to eq(4)
      expect(spotify.flow_bucket).to eq("expense")
    end

    it "keeps the split stable across runs and preserves user edits (no reset / double-count)" do
      gemein = create(:account, bank_connection: bc, iban: nil, role: "giro", role_locked: true)
      invest = create(:account, bank_connection: bc, iban: nil, role: "investment", role_locked: true)
      monthly_dates(4).each.with_index do |d, i|
        charge(name: "Eike Rackwitz", amount: -70.00, date: d,
          transfer_group_id: "gem-#{i}", transfer_counterpart_account: gemein)
      end
      monthly_dates(4).each.with_index do |d, i|
        charge(name: "Eike Rackwitz", amount: -70.00, date: d,
          transfer_group_id: "inv-#{i}", transfer_counterpart_account: invest)
      end

      subject.detect
      transfers = user.recurring_series.where(canonical_name: "Eike Rackwitz")
      expect(transfers.count).to eq(2)
      ids_before = transfers.pluck(:id).sort

      # the user confirms + renames one of the two split series
      pinned = transfers.first
      pinned.update!(user_confirmed: true)
      pinned_id = pinned.id

      2.times { described_class.new(user).detect }

      again = user.recurring_series.where(canonical_name: "Eike Rackwitz")
      expect(again.count).to eq(2)                      # no duplicate spawned
      expect(again.pluck(:id).sort).to eq(ids_before)   # SAME rows reconciled, not reset
      expect(again.find(pinned_id).user_confirmed).to be(true) # user edit survives
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

  # A series is a "transfer" iff its members are matched internal transfers
  # (transfer_group_id, set by the TransferMatcher). flow_bucket derives this LIVE — no
  # sticky column. Lever B (the old bidirectional name-heuristic) is GONE.
  describe "matched-transfer series → transfer bucket" do
    let(:counterpart) { create(:account, bank_connection: bc, role: "giro", role_locked: true) }

    it "buckets a matched internal transfer as transfer, leaving merchants as expense" do
      # money moved to an own account: members carry transfer_group_id (matcher already ran)
      monthly_dates(3).each.with_index do |d, i|
        charge(name: "Umbuchung", amount: -500.00, date: d,
          transfer_group_id: "g#{i}", transfer_counterpart_account: counterpart)
      end
      # control: a genuine subscription (no transfer_group_id) stays a normal expense
      monthly_dates(3).each { |d| charge(name: "Spotify", amount: -12.99, date: d) }

      subject.detect

      expect(user.recurring_series.find_by(canonical_name: "Umbuchung").flow_bucket).to eq("transfer")
      expect(user.recurring_series.find_by(canonical_name: "Spotify").flow_bucket).to eq("expense")
    end

    it "keeps a bidirectional name pair as directional flows when the members are NOT matched" do
      # same counterparty out AND in, but no transfer_group_id → NOT a corroborated internal
      # transfer, so each leg stays a real directional flow (expense / income), not a transfer.
      monthly_dates(3).each { |d| charge(name: "Eike Rackwitz", amount: -70.00, date: d) }
      monthly_dates(3).each { |d| credit(name: "Eike Rackwitz", amount: 70.00, date: d) }

      subject.detect

      buckets = user.recurring_series.where(canonical_name: "Eike Rackwitz").map(&:flow_bucket).uniq.sort
      expect(buckets).to eq(%w[expense income])
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
      # user_confirmed so the memberless decoy survives reconcile (a memberless unconfirmed
      # series would be deleted) — keeps the test isolated to the B2′ matcher.
      far = create(:recurring_series, user: user, canonical_name: "Patreon",
        direction: "outflow", currency: "EUR", fingerprint: fp_patreon,
        cadence: "monthly", cadence_days: 30, user_confirmed: true,
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
      expect(far.amount_min).to eq(-11.00)          # untouched (the -10.30 cluster went to `near`)
      expect(far.last_seen_on).to eq(Date.current - 400)
    end

    it "tie-breaks equidistant same-fingerprint candidates on the lower id" do
      # Both 0.40 from a -10.40 cluster → gaps tie; min_by [gap, id] picks lower id.
      lower_id = create(:recurring_series, user: user, canonical_name: "Patreon",
        direction: "outflow", currency: "EUR", fingerprint: fp_patreon,
        cadence: "monthly", cadence_days: 30,
        expected_amount: -10.00, amount_min: -10.00, amount_max: -10.00,
        occurrences_count: 3, last_seen_on: Date.current - 400)
      # user_confirmed so the memberless decoy survives reconcile (see note above).
      higher_id = create(:recurring_series, user: user, canonical_name: "Patreon",
        direction: "outflow", currency: "EUR", fingerprint: fp_patreon,
        cadence: "monthly", cadence_days: 30, user_confirmed: true,
        expected_amount: -10.80, amount_min: -10.80, amount_max: -10.80,
        occurrences_count: 3, last_seen_on: Date.current - 400)
      expect(lower_id.id).to be < higher_id.id

      monthly_dates(4).each { |d| charge(name: "Patreon", amount: -10.40, date: d) }

      described_class.new(user).detect

      expect(user.recurring_series.count).to eq(2)
      lower_id.reload
      higher_id.reload
      expect(lower_id.occurrences_count).to eq(4)   # lower id won the tie
      expect(higher_id.amount_min).to eq(-10.80)    # untouched (the -10.40 cluster went to lower_id)
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
    # flow_bucket can place it in the Transfers tab. Only the transfer_group_id IS NULL
    # guard keeps it alive; without it the matched transfers silently vanish from detection.
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
      expect(series.flow_bucket).to eq("transfer")
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
    # A memberless active series is not a real recurring pattern (an aggregate of nothing) →
    # it is DELETED outright, regardless of the grace window. Only a series that still HAS
    # members goes through the grace-end (status: "ended") path so its history is preserved.
    it "deletes a memberless active series even within the grace window" do
      series = create(:recurring_series, :monthly, user: user, status: "active",
        canonical_name: "Old Sub", last_seen_on: Date.current - 20, cadence_days: 30)

      described_class.new(user).detect

      expect(RecurringSeries.exists?(series.id)).to be(false)
    end

    it "ends (not deletes) a series WITH members whose latest charge is far past the grace window" do
      series = create(:recurring_series, :monthly, user: user, status: "active",
        canonical_name: "Old Gym", last_seen_on: Date.current - 120, cadence_days: 30)
      # 2 real members (below MIN_OCCURRENCES, so the series is NOT re-detected this run) keep it
      # from being deleted; the stale last_seen routes it through the grace-END path.
      2.times do |i|
        charge(name: "Old Gym", amount: -29.99, date: Date.current - 120 - (i * 30),
          recurring_series: series)
      end

      described_class.new(user).detect

      expect(series.reload.status).to eq("ended")
      expect(TransactionRecord.where(recurring_series_id: series.id).count).to eq(2)
    end

    it "deletes a memberless 'irregular' leftover, but keeps a user_confirmed one" do
      leftover = create(:recurring_series, user: user, status: "active", cadence: "irregular",
        canonical_name: "Old Irregular", last_seen_on: Date.current - 10, cadence_days: 20)
      confirmed = create(:recurring_series, user: user, status: "active", cadence: "irregular",
        canonical_name: "Kept Irregular", last_seen_on: Date.current - 10, cadence_days: 20, user_confirmed: true)

      described_class.new(user).detect

      expect(RecurringSeries.exists?(leftover.id)).to be(false)  # memberless artifact deleted
      expect(confirmed.reload.status).to eq("active")            # user_confirmed protected
    end
  end

  # P4 — a STOPPED series that is still RE-DETECTED from stale historical members (≥3 left in
  # the 540d window) used to linger active forever (the grace-end check was gated behind "not
  # re-detected"). Now the grace check runs for re-detected series too, keyed on last_seen_on.
  describe "P4: auto-end re-detected-but-stopped series" do
    it "ends a stopped non-confirmed monthly series even though its 3 in-window members re-detect it" do
      # 3 monthly charges, all inside the 540d window but the LATEST is ~120 days ago — well past
      # the monthly grace (30*1.5+5 = 50d). The detector re-detects (3 occurrences clear MIN),
      # but the series has stopped → it must be ended, not left active with a phantom next-date.
      [ 120, 150, 180 ].each { |ago| charge(name: "Cancelled Salary", amount: -50.00, date: Date.current - ago) }

      described_class.new(user).detect

      series = user.recurring_series.find_by(canonical_name: "Cancelled Salary")
      expect(series).to be_present
      expect(series.status).to eq("ended")
      # history retained
      expect(TransactionRecord.where(recurring_series_id: series.id).count).to eq(3)
    end

    it "keeps a series with RECENT members active (Spotify-type is never overdue)" do
      monthly_dates(4).each { |d| charge(name: "Spotify", amount: -12.99, date: d) }

      described_class.new(user).detect

      series = user.recurring_series.find_by(canonical_name: "Spotify")
      expect(series.status).to eq("active")
    end

    it "does NOT auto-end a user_confirmed stopped series (user owns that choice)" do
      # Same stopped shape, but user_confirmed → grace-end is skipped; the serializer's `overdue`
      # flag (request spec) is what surfaces it for a manual end.
      [ 120, 150, 180 ].each { |ago| charge(name: "Confirmed Stopped", amount: -50.00, date: Date.current - ago) }
      # pre-create the confirmed series so the re-detect upserts onto it (preserving user_confirmed)
      create(:recurring_series, :monthly, user: user, canonical_name: "Confirmed Stopped",
        direction: "outflow", currency: "EUR", expected_amount: -50.00,
        amount_min: -50.00, amount_max: -50.00, user_confirmed: true, status: "active")

      described_class.new(user).detect

      series = user.recurring_series.find_by(canonical_name: "Confirmed Stopped")
      expect(series.user_confirmed).to be(true)
      expect(series.status).to eq("active")   # NOT auto-ended
    end

    it "auto-revives an ended series when its pattern reappears (regression guard)" do
      # An ended series with members. New occurrences make it re-detect → persist_series upserts
      # status back to active (no status filter on the fingerprint match — only dismissed blocks).
      ended = create(:recurring_series, :monthly, user: user, status: "ended",
        canonical_name: "Revived Sub", direction: "outflow", currency: "EUR",
        expected_amount: -12.99, amount_min: -12.99, amount_max: -12.99)
      # recent monthly charges with the same identity → 3+ occurrences re-detect it
      monthly_dates(3).each { |d| charge(name: "Revived Sub", amount: -12.99, date: d) }

      described_class.new(user).detect

      expect(ended.reload.status).to eq("active")
    end
  end

  # Root refactor (replaces the rejected naive Fix 1): clear-before-relink is now PER-SERIES
  # inside persist_series, so a non-re-detected series KEEPS its members and reconcile_vanished
  # judges it against real data — no "active but 0-member" ghost.
  describe "per-series clear (root fix, replaces Fix 1)" do
    PP_NAME = "PayPal Europe S.à r.l. et Cie S.C.A.".freeze

    def paypal_charge(merchant:, amount:, date:, txcode: nil)
      ref = txcode || rand(10**12..10**13 - 1)
      remit = "#{ref}/PP.6150.PP/. #{merchant}, Ihr Einkauf bei #{merchant}"
      charge(name: PP_NAME, amount: amount, date: date, remittance: remit)
    end

    it "self-heals the prod ghost: re-routes PayPal Europe charges to per-merchant series, old €23 cluster ends with 0 count" do
      # 3 monthly -23.00 charges that BEFORE Fix 2 collapsed under the single PayPal Europe name.
      # With Fix 2 they carry an OpenAI sub-merchant → re-route to an "OpenAI Ireland Limited"
      # series. The bare PayPal Europe coincidence cannot re-form (no rows resolve to it).
      dates = monthly_dates(3)
      dates.each { |d| paypal_charge(merchant: "OpenAI Ireland Limited", amount: -23.00, date: d) }

      subject.detect

      paypal_europe = user.recurring_series.find_by(canonical_name: "Paypal Europe S.à R.l. Et Cie S.c.a.")
      expect(paypal_europe).to be_nil   # ghost never formed
      openai = user.recurring_series.find_by(canonical_name: "Openai Ireland Limited")
      expect(openai).to be_present
      expect(openai.occurrences_count).to eq(3)
      expect(TransactionRecord.where(recurring_series_id: openai.id).count).to eq(3)
    end

    it "ends/zeroes a once-real series after its members re-route to a new merchant identity (ghost repro)" do
      # Build + link a real -23.00 monthly series under a plain (non-PayPal) name first.
      dates = monthly_dates(3)
      txs = dates.map { |d| charge(name: "Mystery Vendor", amount: -23.00, date: d) }
      subject.detect
      old = user.recurring_series.find_by(canonical_name: "Mystery Vendor")
      expect(old).to be_present
      expect(TransactionRecord.where(recurring_series_id: old.id).count).to eq(3)

      # Now mutate those same tx so Fix 2 re-routes them to a distinct PayPal sub-merchant.
      txs.each do |t|
        t.update!(creditor_name: PP_NAME,
          remittance: "#{rand(10**12..10**13 - 1)}/PP.6150.PP/. OpenAI Ireland Limited, Ihr Einkauf bei OpenAI Ireland Limited")
      end

      described_class.new(user).detect

      # the old identity is no longer re-detected → its members re-pointed away → it is now
      # memberless → DELETED outright (no aggregate without members).
      expect(RecurringSeries.exists?(old.id)).to be(false)
      # the tx now belong to the new per-merchant series
      openai = user.recurring_series.find_by(canonical_name: "Openai Ireland Limited")
      expect(openai).to be_present
      expect(TransactionRecord.where(recurring_series_id: openai.id).count).to eq(3)
    end

    it "deletes a memberless active series regardless of cadence/grace (no aggregate without members)" do
      # quarterly series, last charge within grace (91*1.5+5 ≈ 142d), ZERO live members.
      # Memberless ⇒ not a real series ⇒ deleted (the prior 'retain within grace' behavior is gone).
      series = create(:recurring_series, user: user, status: "active", cadence: "quarterly",
        cadence_days: 91, canonical_name: "Quarterly Contract", last_seen_on: Date.current - 100)

      described_class.new(user).detect

      expect(RecurringSeries.exists?(series.id)).to be(false)
    end

    it "moves a tx from series A to series B without a double link" do
      # A real Spotify series exists and links its 4 tx.
      monthly_dates(4).each { |d| charge(name: "Spotify", amount: -12.99, date: d) }
      subject.detect
      a = user.recurring_series.find_by(canonical_name: "Spotify")
      stray = TransactionRecord.where(recurring_series_id: a.id).first

      # Force the stray to point at a DIFFERENT pre-existing series B (simulate prior-run state),
      # then re-run: it must end up linked ONLY to whatever series it actually clusters into.
      b = create(:recurring_series, user: user, canonical_name: "Other", direction: "outflow",
        currency: "EUR", expected_amount: -99.00)
      stray.update!(recurring_series_id: b.id)

      described_class.new(user).detect

      stray.reload
      expect(stray.recurring_series_id).to eq(a.id)   # back in its real cluster, only once
      expect(TransactionRecord.where(recurring_series_id: b.id).count).to eq(0)
    end

    it "shrinks cleanly: a dropped tx ends with recurring_series_id nil (A4)" do
      monthly_dates(4).each { |d| charge(name: "Spotify", amount: -12.99, date: d) }
      subject.detect
      series = user.recurring_series.find_by(canonical_name: "Spotify")

      stray = charge(name: "Unrelated One-Off", amount: -7.77, date: Date.current - 2)
      stray.update!(recurring_series_id: series.id)

      described_class.new(user).detect

      expect(stray.reload.recurring_series_id).to be_nil
      expect(TransactionRecord.where(recurring_series_id: series.id).count).to eq(4)
    end

    it "converges: a memberless ghost is deleted and real series stay intact across runs" do
      monthly_dates(4).each { |d| charge(name: "Spotify", amount: -12.99, date: d) }
      dead = create(:recurring_series, :monthly, user: user, status: "active",
        canonical_name: "Dead Sub", last_seen_on: Date.current - 200, cadence_days: 30)

      subject.detect
      expect(RecurringSeries.exists?(dead.id)).to be(false)   # memberless ghost deleted
      spotify = user.recurring_series.find_by(canonical_name: "Spotify")
      expect(spotify.occurrences_count).to eq(4)

      described_class.new(user).detect

      expect(spotify.reload.occurrences_count).to eq(4)
      expect(TransactionRecord.where(recurring_series_id: spotify.id).count).to eq(4)
    end

    it "keeps a user_confirmed memberless series active and syncs its count to 0 (cosmetic)" do
      series = create(:recurring_series, user: user, status: "active", cadence: "monthly",
        cadence_days: 30, canonical_name: "Confirmed Sub", user_confirmed: true,
        last_seen_on: Date.current - 20, occurrences_count: 4)

      described_class.new(user).detect

      series.reload
      expect(series.status).to eq("active")        # user_confirmed protection intact
      expect(series.occurrences_count).to eq(0)    # honest: 0 live members
    end
  end

  describe "aggregator sub-merchant extraction (Fix 2)" do
    PP_CREDITOR = "PayPal Europe S.à r.l. et Cie S.C.A.".freeze

    it "resolves a PayPal sub-merchant from the remittance, not the aggregator name (a)" do
      dates = monthly_dates(3)
      dates.each do |d|
        charge(name: PP_CREDITOR, amount: -23.00, date: d,
          remittance: "1048683274758/PP.6150.PP/. OpenAI Ireland Limited, Ihr Einkauf bei OpenAI Ireland Limited")
      end

      subject.detect

      expect(user.recurring_series.find_by(canonical_name: "Openai Ireland Limited")).to be_present
      expect(user.recurring_series.where("canonical_name LIKE ?", "%Paypal Europe%")).to be_empty
      expect(user.recurring_series.where("canonical_name LIKE ?", "%6150%")).to be_empty
    end

    it "falls back to 'PayPal' for an empty-merchant remittance (b)" do
      # empty merchant → generic PayPal → too generic + irregular → no series, but no raise/blank key
      dates = monthly_dates(3)
      dates.each do |d|
        charge(name: PP_CREDITOR, amount: -5.00, date: d, remittance: "1047204316922/PP.6150.PP/. , Ihr Einkauf bei ")
      end

      expect { subject.detect }.not_to raise_error
      series = user.recurring_series.first
      expect(series.canonical_name).to eq("Paypal") if series   # generic, never a numeric key
      expect(MerchantAlias.where(user: user).pluck(:raw_key)).not_to include(a_string_matching(/\A\d/))
    end

    it "preserves a comma inside the merchant name up to the first delimiter (c)" do
      detector = described_class.new(user)
      tx = charge(name: PP_CREDITOR, amount: -50.00, date: Date.current - 5,
        remittance: "1099/PP.6150.PP/. CTS Eventim AG & Co. KGaA, Ihr Einkauf bei CTS Eventim AG & Co. KGaA")
      raw = detector.send(:counterparty_raw, tx.reload, "outflow")
      expect(raw).to eq("CTS Eventim AG & Co. KGaA")
    end

    it "extracts the merchant from a remittance with no PP.NNN.PP token (d)" do
      detector = described_class.new(user)
      tx = charge(name: PP_CREDITOR, amount: -30.00, date: Date.current - 5,
        remittance: "1047167713938/. LogPay Financial Services GmbH, Ihr Einkauf bei LogPay Financial Services GmbH")
      raw = detector.send(:counterparty_raw, tx.reload, "outflow")
      expect(raw).to eq("LogPay Financial Services GmbH")
    end

    it "does NOT parse the remittance for a non-PayPal creditor (e)" do
      detector = described_class.new(user)
      tx = charge(name: "Amazon Payments Europe S.C.A.", amount: -20.00, date: Date.current - 5,
        remittance: "1234/PP.6150.PP/. Something, Ihr Einkauf bei Something")
      raw = detector.send(:counterparty_raw, tx.reload, "outflow")
      expect(raw).to eq("Amazon Payments Europe S.C.A.")   # creditor_name untouched
    end

    it "detects the real OpenAI monthly subscription across price drift as one variable series (f)" do
      # gentle drift, small consecutive gaps (< max(0.15·amt, 0.50)) → ONE cluster, but the
      # total span (4.00 / ~22 ≈ 0.18 > 0.15 tolerance) makes it amount_variable.
      amounts = [ -20.00, -22.00, -23.00, -24.00 ]
      monthly_dates(4).each_with_index do |d, i|
        charge(name: PP_CREDITOR, amount: amounts[i], date: d,
          remittance: "10480#{i}54003144/PP.6150.PP/. OpenAI Ireland Limited, Ihr Einkauf bei OpenAI Ireland Limited")
      end

      subject.detect

      openai = user.recurring_series.find_by(canonical_name: "Openai Ireland Limited")
      expect(openai).to be_present
      expect(openai.cadence).to eq("monthly")
      expect(openai.amount_variable).to be(true)
      expect(openai.occurrences_count).to be >= 3
      expect(TransactionRecord.where(recurring_series_id: openai.id).count).to be >= 3
    end

    it "leaves one-off PayPal sub-merchants undetected and out of the LLM batch (g)" do
      # two irregular DB tickets → < MIN_OCCURRENCES → no series, and the singleton key is
      # never persisted as a MerchantAlias (explosion gate).
      [ Date.current - 5, Date.current - 40 ].each do |d|
        charge(name: PP_CREDITOR, amount: -19.90, date: d,
          remittance: "1099/PP.6150.PP/. DB Vertrieb GmbH, Ihr Einkauf bei DB Vertrieb GmbH")
      end

      subject.detect

      expect(user.recurring_series.where("canonical_name LIKE ?", "%Db Vertrieb%")).to be_empty
      expect(MerchantAlias.where(user: user).where("raw_key LIKE ?", "%db vertrieb%")).to be_empty
    end

    it "does not collapse distinct sub-merchants sharing one amount into a €23 coincidence (h)" do
      # 3 different merchants, all -23.00, one each → each a singleton → no €23 series forms.
      [ "Lotto24 AG", "Mullvad VPN AB", "DB Vertrieb GmbH" ].each_with_index do |merchant, i|
        charge(name: PP_CREDITOR, amount: -23.00, date: Date.current - (i * 30 + 5),
          remittance: "10#{i}99/PP.6150.PP/. #{merchant}, Ihr Einkauf bei #{merchant}")
      end

      subject.detect

      expect(user.recurring_series.where(expected_amount: -23.00)).to be_empty
      expect(user.recurring_series.count).to eq(0)
    end

    # PART 1 — a PayPal leg that is ALREADY a matched conduit transfer to an own account
    # (transfer_group_id + transfer_counterpart_account_id set by the TransferMatcher) must NOT
    # have its sub-merchant extracted: the real expense lives on the OTHER leg booked on the
    # PayPal account. Extraction here would relabel the conduit leg "OpenAI" → a confusing
    # "OpenAI Umbuchung". So counterparty_raw falls back to the (junk) aggregator name instead.
    it "does NOT extract a sub-merchant for a matched PayPal conduit leg (Part 1)" do
      own = create(:account, bank_connection: bc, iban: nil)
      detector = described_class.new(user)
      tx = charge(name: PP_CREDITOR, amount: -23.00, date: Date.current - 5,
        remittance: "1099/PP.6150.PP/. OpenAI Ireland Limited, Ihr Einkauf bei OpenAI Ireland Limited",
        transfer_group_id: SecureRandom.uuid, transfer_counterpart_account: own)
      raw = detector.send(:counterparty_raw, tx.reload, "outflow")
      expect(raw).not_to eq("OpenAI Ireland Limited")
      expect(raw).to eq(PP_CREDITOR)   # falls back to the aggregator creditor name
    end

    it "STILL extracts a sub-merchant for a genuinely-unmatched PayPal purchase (Part 1 regression)" do
      detector = described_class.new(user)
      # no transfer link → normal PayPal purchase → sub-merchant extraction preserved (#67 guard)
      tx = charge(name: PP_CREDITOR, amount: -23.00, date: Date.current - 5,
        remittance: "1099/PP.6150.PP/. OpenAI Ireland Limited, Ihr Einkauf bei OpenAI Ireland Limited")
      raw = detector.send(:counterparty_raw, tx.reload, "outflow")
      expect(raw).to eq("OpenAI Ireland Limited")
    end

    it "matched PayPal conduit legs collapse into no series (the 'OpenAI Umbuchung' is gone)" do
      own = create(:account, bank_connection: bc, iban: nil)
      # 3 monthly conduit legs to an own account, each carrying an OpenAI sub-merchant in the
      # remittance. With Part 1 they fall back to the junk PayPal Europe name → one irregular
      # blob build_series rejects → NO "OpenAI" transfer series forms.
      monthly_dates(3).each.with_index do |d, i|
        charge(name: PP_CREDITOR, amount: -23.00, date: d,
          remittance: "10#{i}99/PP.6150.PP/. OpenAI Ireland Limited, Ihr Einkauf bei OpenAI Ireland Limited",
          transfer_group_id: "pp-#{i}", transfer_counterpart_account: own)
      end

      subject.detect

      expect(user.recurring_series.where(canonical_name: "Openai Ireland Limited")).to be_empty
    end

    it "falls back to 'PayPal' for a refund inflow (PP prefix, no 'Ihr Einkauf bei') (10)" do
      detector = described_class.new(user)
      tx = credit(name: PP_CREDITOR, amount: 15.00, date: Date.current - 5,
        remittance: "1050/PP.6150.PP/. Rückzahlung OpenAI Ireland Limited")
      raw = detector.send(:counterparty_raw, tx.reload, "inflow")
      expect(raw).to eq("PayPal")   # no suffix → generic fallback, stays irregular
    end
  end

  describe "variable-amount salary detection (Part 2)" do
    SALARY_IBAN = "DE00000000000000766300".freeze

    def salary(amount:, date:)
      credit(name: "Pludoni GmbH", amount: amount, date: date, debtor_iban: SALARY_IBAN)
    end

    it "detects a varying monthly salary as ONE income series, bypassing amount-subclustering" do
      # 4 distinct months of salary at DIFFERENT amounts (would each fall in their own amount
      # sub-cluster < MIN_OCCURRENCES under the normal path → missed).
      salary(amount: 1101.73, date: Date.current - 95)
      salary(amount: 2042.64, date: Date.current - 65)
      salary(amount: 1920.78, date: Date.current - 35)
      salary(amount: 1920.78, date: Date.current - 5)

      subject.detect

      series = user.recurring_series.inflows.find_by(canonical_name: "Pludoni Gmbh")
      expect(series).to be_present
      expect(series.cadence).to eq("monthly")
      expect(series.amount_variable).to be(true)
      expect(series.occurrences_count).to eq(4)
      # median of the four amounts (1101.73, 1920.78, 1920.78, 2042.64) = 1920.78
      expect(series.expected_amount).to eq(1920.78)
    end

    it "drops a micro-outlier (Nachzahlung) so it neither sets expected_amount nor poisons cv" do
      salary(amount: 1101.73, date: Date.current - 95)
      salary(amount: 2042.64, date: Date.current - 65)
      salary(amount: 1920.78, date: Date.current - 35)
      salary(amount: 1920.78, date: Date.current - 5)
      # a 4.69 "Nachzahlung Lohn" micro-row, same payer/IBAN, well under 10% of the ~1920 median
      salary(amount: 4.69, date: Date.current - 4)

      subject.detect

      series = user.recurring_series.inflows.find_by(canonical_name: "Pludoni Gmbh")
      expect(series).to be_present
      expect(series.amount_min).to be > 4.69        # the micro-row never entered the amount span
      expect(series.expected_amount).to eq(1920.78) # unchanged by the outlier
    end

    it "collapses two payments in the same month into ONE node (median amount, latest date)" do
      salary(amount: 1097.04, date: Date.current - 96)   # Jan-equivalent month, first payment
      salary(amount: 2194.08, date: Date.current - 95)   # SAME month back-pay (latest date)
      salary(amount: 1920.78, date: Date.current - 65)
      salary(amount: 1920.78, date: Date.current - 35)
      salary(amount: 1920.78, date: Date.current - 5)

      subject.detect

      series = user.recurring_series.inflows.find_by(canonical_name: "Pludoni Gmbh")
      expect(series).to be_present
      # 5 raw rows collapse to 4 monthly NODES (two share one calendar month)
      expect(series.occurrences_count).to eq(4)
      # but ALL underlying transactions are linked as members (history preserved)
      expect(TransactionRecord.where(recurring_series_id: series.id).count).to eq(5)
      # collapsed-month amount is the MEDIAN (not the 2194.08 back-pay max) → forecast not inflated
      expect(series.expected_amount).to eq(1920.78)
    end

    it "NEVER fuses unrelated inflows from different counterparty IBANs" do
      # same canonical name but two DIFFERENT payer IBANs → the IBAN gate forbids the variable
      # path → neither reaches 3 occurrences alone → no salary series fuses them.
      credit(name: "Pludoni GmbH", amount: 1900.00, date: Date.current - 65, debtor_iban: SALARY_IBAN)
      credit(name: "Pludoni GmbH", amount: 500.00, date: Date.current - 35, debtor_iban: "DE99999999999999999999")
      credit(name: "Pludoni GmbH", amount: 2100.00, date: Date.current - 5, debtor_iban: SALARY_IBAN)

      subject.detect

      expect(user.recurring_series.inflows.where(canonical_name: "Pludoni Gmbh")).to be_empty
    end

    it "does not fire for only 2 monthly IBAN-consistent inflows (MIN_OCCURRENCES gate)" do
      salary(amount: 1900.00, date: Date.current - 35)
      salary(amount: 2100.00, date: Date.current - 5)

      result = subject.detect

      expect(result[:detected]).to eq(0)
      expect(user.recurring_series.inflows.where(canonical_name: "Pludoni Gmbh")).to be_empty
    end

    it "still detects a fixed-amount IBAN-consistent inflow (variable path does not regress it)" do
      monthly_dates(4).each { |d| credit(name: "Stable Employer", amount: 2500.00, date: d, debtor_iban: "DE12120000000000000001") }

      subject.detect

      series = user.recurring_series.inflows.find_by(canonical_name: "Stable Employer")
      expect(series).to be_present
      expect(series.expected_amount).to eq(2500.00)
      expect(series.occurrences_count).to eq(4)
    end
  end

  # Part-2 regression fix: an inflow [payer, account, cp] group is now sub-grouped by a normalized
  # Verwendungszweck (purpose_key) so each (payer, purpose) is its own candidate. This splits a
  # person who sends MANY recurring streams (Katja) into distinct series, WITHOUT re-breaking a
  # salary whose purpose is stable but whose betreff text varies (Pludoni). Outflows/merchants are
  # NOT purpose-split. credit() must pass debtor_iban: — the inflow paths require IBAN-consistency.
  describe "inflow purpose sub-grouping" do
    KATJA_IBAN   = "DE00000000000000167706".freeze
    PLUDONI_IBAN = "DE00000000000000766300".freeze

    # 5 monthly anchors, oldest→newest (newest = today-5), spaced ~30d.
    def five_months
      [ 125, 95, 65, 35, 5 ].map { |ago| Date.current - ago }
    end

    it "splits one payer's distinct purposes into separate monthly series and leaves one-offs unmatched (A)" do
      # FIVE distinct recurring monthly streams, all from ONE payer / ONE debtor IBAN …
      five_months.each { |d| credit(name: "Katja Stumpf", amount: 445.00, date: d, debtor_iban: KATJA_IBAN, remittance: "Miete") }
      five_months.each { |d| credit(name: "Katja Stumpf", amount: 31.00,  date: d, debtor_iban: KATJA_IBAN, remittance: "Strom") }
      five_months.each { |d| credit(name: "Katja Stumpf", amount: 16.50,  date: d, debtor_iban: KATJA_IBAN, remittance: "Internet") }
      five_months.each { |d| credit(name: "Katja Stumpf", amount: 20.00,  date: d, debtor_iban: KATJA_IBAN, remittance: "ETF Alma") }
      # Ansparen only 3 months (exactly MIN_OCCURRENCES) …
      five_months.last(3).each { |d| credit(name: "Katja Stumpf", amount: 70.00, date: d, debtor_iban: KATJA_IBAN, remittance: "Ansparen") }
      # … plus one-offs that must NOT become series (each a distinct singleton purpose key)
      credit(name: "Katja Stumpf", amount: 1200.00, date: Date.current - 50, debtor_iban: KATJA_IBAN, remittance: "")
      credit(name: "Katja Stumpf", amount: 300.00,  date: Date.current - 40, debtor_iban: KATJA_IBAN, remittance: "Geldgeschenke Malin")
      credit(name: "Katja Stumpf", amount: 428.00,  date: Date.current - 30, debtor_iban: KATJA_IBAN, remittance: "Urlaub Mallorca")

      subject.detect

      series = user.recurring_series.inflows.where(canonical_name: "Katja Stumpf")
      expect(series.count).to eq(5)
      expect(series.map { |s| s.expected_amount.to_f }).to contain_exactly(445.0, 31.0, 16.5, 20.0, 70.0)
      series.each { |s| expect(s.cadence).to eq("monthly") }
      # the one-offs formed NO series
      [ 1200.00, 300.00, 428.00 ].each do |amt|
        expect(user.recurring_series.where(expected_amount: amt)).to be_empty
      end
    end

    it "keeps a salary's varied 'Lohn/Gehalt …' betreff as ONE variable monthly income series (B)" do
      # same payer/IBAN, SIX months, varied betreff text, VARYING amount — must stay ONE series.
      rows = [
        [ 1097.04, "Lohn/Gehalt 2026/01" ],
        [ 2194.08, "Lohn/Gehalt 2025/10 und 2025/12 bzw. 2025/09 und 2025/11" ],
        [ 1101.73, "Lohn/Gehalt 2026/02" ],
        [ 2042.64, "Lohn/Gehalt 03 2026" ],
        [ 1920.78, "Lohn/Gehalt pludoni" ],
        [ 1920.78, "Lohn/Gehalt pludoni" ]
      ]
      [ 155, 125, 95, 65, 35, 5 ].each_with_index do |ago, i|
        amount, betreff = rows[i]
        credit(name: "Pludoni GmbH", amount: amount, date: Date.current - ago, debtor_iban: PLUDONI_IBAN, remittance: betreff)
      end

      subject.detect

      series = user.recurring_series.inflows.where(canonical_name: "Pludoni Gmbh")
      expect(series.count).to eq(1)
      s = series.first
      expect(s.cadence).to eq("monthly")
      expect(s.amount_variable).to be(true)
      expect(s.occurrences_count).to eq(6)
      # ALL six real payments linked to the one series
      expect(TransactionRecord.where(recurring_series_id: s.id).count).to eq(6)
    end

    it "normalizes month/date tokens away so 'Miete 06/2026' / '07/2026' / 'Miete' form ONE series (C)" do
      remits = [ "Miete 06/2026", "Miete 07/2026", "Miete" ]
      [ 65, 35, 5 ].each_with_index do |ago, i|
        credit(name: "Katja Stumpf", amount: 445.00, date: Date.current - ago, debtor_iban: KATJA_IBAN, remittance: remits[i])
      end

      subject.detect

      series = user.recurring_series.inflows.where(canonical_name: "Katja Stumpf")
      expect(series.count).to eq(1)
      expect(TransactionRecord.where(recurring_series_id: series.first.id).count).to eq(3)
    end

    it "does NOT merge distinct purposes at near-equal amounts (Miete 445 vs Urlaub 428) (D)" do
      # same payer/IBAN, monthly, amounts within §5.3's tolerance band of each other — but DIFFERENT
      # purposes → different sub-groups → two series (amount proximity is irrelevant across purposes).
      five_months.first(4).each { |d| credit(name: "Katja Stumpf", amount: 445.00, date: d, debtor_iban: KATJA_IBAN, remittance: "Miete") }
      five_months.first(4).each { |d| credit(name: "Katja Stumpf", amount: 428.00, date: d, debtor_iban: KATJA_IBAN, remittance: "Urlaub Mallorca") }

      subject.detect

      series = user.recurring_series.inflows.where(canonical_name: "Katja Stumpf")
      expect(series.count).to eq(2)
      expect(series.map { |s| s.expected_amount.to_f }).to contain_exactly(445.0, 428.0)
    end

    it "does NOT purpose-split outflows: a merchant with varying remittances stays ONE series (E regression guard)" do
      # Spotify with a DIFFERENT ref-number betreff each month — if purpose-splitting wrongly applied
      # to outflows, this would shatter into singletons. The outflow branch must keep it ONE series.
      monthly_dates(4).each_with_index do |d, i|
        charge(name: "Spotify", amount: -12.99, date: d, remittance: "Abrechnung #{1000 + i}/2026 Beleg")
      end

      subject.detect

      series = user.recurring_series.outflows.where(canonical_name: "Spotify")
      expect(series.count).to eq(1)
      expect(series.first.occurrences_count).to eq(4)
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
