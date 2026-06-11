require "rails_helper"

RSpec.describe TransferMatcher do
  let(:user) { create(:user) }
  let(:bc) { create(:bank_connection, user: user) }

  # Two own accounts with IBANs (Tomorrow-style). role_locked so the inferrer
  # after_commit hook can't fight us; IBANs are the (a) corroboration source.
  let(:privat) { create(:account, bank_connection: bc, iban: "DE11111111111111111111", name: "Privat", role_locked: true) }
  let(:gemeinschaft) { create(:account, bank_connection: bc, iban: "DE22222222222222222222", name: "Gemeinschaft", role_locked: true) }
  # IBAN-less account (Trade Republic style): the name path is the only signal.
  let(:trade_republic) { create(:account, bank_connection: bc, iban: nil, name: "Trade Republic", role_locked: true) }

  subject { described_class.new(user) }

  def leg(account:, amount:, date: Date.current, **extra)
    create(:transaction_record, account: account, amount: amount,
      booking_date: date, currency: "EUR", creditor_name: nil, debtor_name: nil,
      remittance: nil, **extra)
  end

  describe "IBAN-corroborated pairing" do
    it "pairs −70 Privat with +70 Gemeinschaft on the same day" do
      # Outflow leaves Privat toward Gemeinschaft (creditor IBAN = own account).
      out = leg(account: privat, amount: -70.00, creditor_iban: gemeinschaft.iban)
      # Inflow lands on Gemeinschaft from Privat (debtor IBAN = own account).
      inn = leg(account: gemeinschaft, amount: 70.00, debtor_iban: privat.iban)

      subject.match

      out.reload
      inn.reload
      expect(out.transfer_group_id).to be_present
      expect(out.transfer_group_id).to eq(inn.transfer_group_id)
      expect(out.transfer_counterpart_account_id).to eq(gemeinschaft.id)
      expect(inn.transfer_counterpart_account_id).to eq(privat.id)
    end

    it "pairs within the ±4 day window but not beyond it" do
      out = leg(account: privat, amount: -70.00, date: Date.current, creditor_iban: gemeinschaft.iban)
      inn = leg(account: gemeinschaft, amount: 70.00, date: Date.current + 4, debtor_iban: privat.iban)
      far = leg(account: privat, amount: -50.00, date: Date.current, creditor_iban: gemeinschaft.iban)
      far_inn = leg(account: gemeinschaft, amount: 50.00, date: Date.current + 5, debtor_iban: privat.iban)

      subject.match

      expect(out.reload.transfer_group_id).to eq(inn.reload.transfer_group_id)
      expect(far.reload.transfer_group_id).to be_nil
      expect(far_inn.reload.transfer_group_id).to be_nil
    end
  end

  describe "name corroboration (IBAN-less, Trade Republic)" do
    # The holder name "Eike Mustermann" is grounded as an OWN holder by a prior
    # IBAN-corroborated move (creditor IBAN = own Gemeinschaft account): that leg
    # banks the name so an IBAN-less ±X TR pair carrying the same name can match.
    let!(:grounding) do
      [
        leg(account: privat, amount: -10.00, creditor_iban: gemeinschaft.iban, creditor_name: "Eike Mustermann"),
        leg(account: gemeinschaft, amount: 10.00, debtor_iban: privat.iban, debtor_name: "Eike Mustermann")
      ]
    end

    it "pairs an IBAN-less ±X pair when the matched name is an own holder" do
      out = leg(account: trade_republic, amount: -100.00, creditor_name: "Eike Mustermann")
      inn = leg(account: gemeinschaft, amount: 100.00, debtor_name: "Eike Mustermann")

      subject.match

      expect(out.reload.transfer_group_id).to be_present
      expect(out.transfer_group_id).to eq(inn.reload.transfer_group_id)
    end

    it "does NOT pair a −50/+50 'Amazon' expense+refund (Amazon is not an own holder)" do
      # Cross-leg name equality alone is a trap: an expense and its refund both
      # name the merchant. Amazon is never an own holder, so this must not pair.
      expense = leg(account: privat, amount: -50.00, creditor_name: "Amazon")
      refund  = leg(account: gemeinschaft, amount: 50.00, debtor_name: "Amazon")

      subject.match

      expect(expense.reload.transfer_group_id).to be_nil
      expect(refund.reload.transfer_group_id).to be_nil
    end
  end

  describe "one-sided contributions (Katja)" do
    it "does not pair an inflow that has no corroborated counter-outflow" do
      inn = leg(account: gemeinschaft, amount: 70.00, debtor_name: "Katja Externa")

      subject.match

      expect(inn.reload.transfer_group_id).to be_nil
    end
  end

  describe "B1 guard — corroboration is mandatory" do
    it "does NOT pair a real expense with an unrelated inflow of equal amount" do
      # A genuine −70 expense to an external merchant (no own IBAN, different name).
      expense = leg(account: privat, amount: -70.00, creditor_name: "REWE Markt GmbH",
        creditor_iban: "DE99999999999999999999")
      # Katja's coincidental +70 income the same day — no corroboration at all.
      income = leg(account: gemeinschaft, amount: 70.00, debtor_name: "Katja Externa")

      subject.match

      expect(expense.reload.transfer_group_id).to be_nil
      expect(income.reload.transfer_group_id).to be_nil
    end
  end

  describe "remittance corroboration (transfer hints)" do
    it "pairs when BOTH legs carry a transfer hint" do
      out = leg(account: privat, amount: -200.00, remittance: "Umbuchung Sparen")
      inn = leg(account: gemeinschaft, amount: 200.00, remittance: "Umbuchung von Privat")

      subject.match

      expect(out.reload.transfer_group_id).to be_present
      expect(out.transfer_group_id).to eq(inn.reload.transfer_group_id)
    end

    it "does NOT pair a lone 'Umbuchung' outflow with an unrelated salary inflow" do
      # The outflow says "Umbuchung" but the inflow is a real salary of the same
      # amount — a one-sided hint must not silently erase income+expense.
      transfer_out = leg(account: privat, amount: -200.00, remittance: "Umbuchung Sparen")
      salary_in    = leg(account: gemeinschaft, amount: 200.00, remittance: "Gehalt Juni",
        debtor_name: "Arbeitgeber GmbH")

      subject.match

      expect(transfer_out.reload.transfer_group_id).to be_nil
      expect(salary_in.reload.transfer_group_id).to be_nil
    end
  end

  describe "idempotency" do
    it "does not double-pair on a second run" do
      out = leg(account: privat, amount: -70.00, creditor_iban: gemeinschaft.iban)
      inn = leg(account: gemeinschaft, amount: 70.00, debtor_iban: privat.iban)

      subject.match
      group_id = out.reload.transfer_group_id

      described_class.new(user).match

      expect(out.reload.transfer_group_id).to eq(group_id)
      expect(inn.reload.transfer_group_id).to eq(group_id)
    end
  end

  describe "deterministic 1:1 pairing (S1, @claimed)" do
    it "pairs two equal amounts on the same day 1:1 without crossing over" do
      out_a = leg(account: privat, amount: -70.00, creditor_iban: gemeinschaft.iban)
      out_b = leg(account: privat, amount: -70.00, creditor_iban: gemeinschaft.iban)
      inn_a = leg(account: gemeinschaft, amount: 70.00, debtor_iban: privat.iban)
      inn_b = leg(account: gemeinschaft, amount: 70.00, debtor_iban: privat.iban)

      subject.match

      groups = [ out_a, out_b, inn_a, inn_b ].map { |t| t.reload.transfer_group_id }
      expect(groups).to all(be_present)
      # exactly two distinct groups, each shared by exactly two legs
      expect(groups.tally.values).to contain_exactly(2, 2)
    end
  end

  describe "S2 — deleted counterpart un-matches the surviving leg" do
    it "drops transfer_group_id when the counterpart account was nullified" do
      out = leg(account: privat, amount: -70.00, creditor_iban: gemeinschaft.iban)
      inn = leg(account: gemeinschaft, amount: 70.00, debtor_iban: privat.iban)
      subject.match
      expect(out.reload.transfer_group_id).to be_present

      # Delete the counterpart account → FK on_delete: :nullify clears
      # transfer_counterpart_account_id on the surviving leg AND removes its legs.
      gemeinschaft.destroy!

      described_class.new(user).match

      out.reload
      expect(out.transfer_counterpart_account_id).to be_nil
      expect(out.transfer_group_id).to be_nil
    end
  end

  # PayPal-conduit recognition: a bank↔PayPal flow is a one-legged, same-sign
  # transfer to the user's PayPal ASSET account. Classified by COUNTERPARTY
  # (PayPal Europe ...200E / "PayPal Europe"), never by 1:1 amount matching.
  describe "PayPal conduit (one-legged transfer to the PayPal account)" do
    # The user's PayPal account, identified by its bank_connection provider.
    let(:paypal_bc) { create(:bank_connection, :paypal, user: user) }
    let!(:paypal) { create(:account, bank_connection: paypal_bc, account_uid: "paypal", iban: nil, name: "PayPal", role_locked: true) }

    it "marks a giro→PayPal funding Lastschrift (debit) as a transfer to the PayPal account" do
      # The real funding-Lastschrift shape: −188,95 to PayPal Europe S.à r.l.,
      # creditor IBAN ending …200E.
      funding = leg(account: privat, amount: -188.95,
        creditor_name: "PayPal Europe S.a.r.l. et Cie S.C.A",
        creditor_iban: "LU89751000135104200E",
        remittance: "PP.6150.PP TRMNL")

      subject.match

      funding.reload
      expect(funding.transfer_counterpart_account_id).to eq(paypal.id)
      expect(funding.transfer_group_id).to be_present
    end

    it "marks a PayPal→giro withdrawal (credit) as a transfer to the PayPal account" do
      # User withdraws their PayPal balance back to the bank: a giro CREDIT whose
      # DEBTOR is PayPal Europe.
      withdrawal = leg(account: privat, amount: 250.00,
        creditor_name: nil, debtor_name: "PayPal Europe S.a.r.l. et Cie S.C.A",
        debtor_iban: "LU89751000135104200E", remittance: "PayPal Auszahlung")

      subject.match

      withdrawal.reload
      expect(withdrawal.transfer_counterpart_account_id).to eq(paypal.id)
      expect(withdrawal.transfer_group_id).to be_present
    end

    it "matches by counterparty NAME when the IBAN is missing (fallback)" do
      funding = leg(account: privat, amount: -42.00,
        creditor_name: "PayPal Europe S.a.r.l. et Cie S.C.A", creditor_iban: nil,
        remittance: "PP.1234.PP")

      subject.match

      expect(funding.reload.transfer_counterpart_account_id).to eq(paypal.id)
    end

    it "does NOT touch the PayPal account's OWN purchase row (it stays an expense, counted once)" do
      # The actual −188,95 "TRMNL" purchase lives ON the PayPal account. It must
      # NOT be reclassified — it is the single expense the dashboard should show.
      purchase = leg(account: paypal, amount: -188.95, creditor_name: "TRMNL", remittance: "TRMNL")

      subject.match

      purchase.reload
      expect(purchase.transfer_group_id).to be_nil
      expect(purchase.transfer_counterpart_account_id).to be_nil
    end

    it "is idempotent — a second run keeps the same group_id" do
      funding = leg(account: privat, amount: -188.95,
        creditor_name: "PayPal Europe S.a.r.l. et Cie S.C.A", creditor_iban: "LU89751000135104200E")

      subject.match
      group_id = funding.reload.transfer_group_id
      expect(group_id).to be_present

      described_class.new(user).match

      expect(funding.reload.transfer_group_id).to eq(group_id)
      expect(funding.transfer_counterpart_account_id).to eq(paypal.id)
    end

    it "does NOT mark a 'PayPal Europe'-named row carrying a NON-200E IBAN (IBAN is authoritative)" do
      # A PayPal-branded service/fee billed from a different IBAN is NOT a wallet
      # top-up — the IBAN, when present, overrides the name fallback.
      fee = leg(account: privat, amount: -9.99,
        creditor_name: "PayPal Europe S.a.r.l. et Cie S.C.A",
        creditor_iban: "DE12345678901234567890")

      subject.match

      fee.reload
      expect(fee.transfer_group_id).to be_nil
      expect(fee.transfer_counterpart_account_id).to be_nil
    end

    it "matches the canonical parenthesised name 'PayPal (Europe) S.à r.l.' on an IBAN-less row" do
      funding = leg(account: privat, amount: -19.00, creditor_iban: nil,
        creditor_name: "PayPal (Europe) S.à r.l. et Cie, S.C.A.", remittance: "PP.9999.PP")

      subject.match

      expect(funding.reload.transfer_counterpart_account_id).to eq(paypal.id)
    end

    it "preserves a user category on a funding leg it marks (only the transfer FKs change)" do
      cat = create(:category, user: user)
      funding = leg(account: privat, amount: -188.95, category: cat,
        creditor_name: "PayPal Europe S.a.r.l. et Cie S.C.A", creditor_iban: "LU89751000135104200E")

      subject.match

      funding.reload
      expect(funding.transfer_counterpart_account_id).to eq(paypal.id)
      expect(funding.category_id).to eq(cat.id)
    end
  end

  describe "PayPal conduit guard — no PayPal account" do
    # NO PayPal connection here: paypal_account_id is nil, so the pass is inert.
    it "leaves a giro→PayPal debit as a real expense when the user has no PayPal account" do
      funding = leg(account: privat, amount: -188.95,
        creditor_name: "PayPal Europe S.a.r.l. et Cie S.C.A", creditor_iban: "LU89751000135104200E")

      subject.match

      funding.reload
      expect(funding.transfer_group_id).to be_nil
      expect(funding.transfer_counterpart_account_id).to be_nil
    end

    it "leaves a non-PayPal REWE debit untouched even with a PayPal account present" do
      create(:account, bank_connection: create(:bank_connection, :paypal, user: user),
        account_uid: "paypal", iban: nil, name: "PayPal", role_locked: true)
      rewe = leg(account: privat, amount: -188.95, creditor_name: "REWE Markt GmbH",
        creditor_iban: "DE99999999999999999999")

      subject.match

      rewe.reload
      expect(rewe.transfer_group_id).to be_nil
      expect(rewe.transfer_counterpart_account_id).to be_nil
    end
  end

  # The conduit pass must not disturb the existing +/− matcher: the easybank
  # giro −X ↔ card +X settlement still pairs as a real two-leg transfer.
  describe "does not break the existing two-leg (easybank-style) settlement matching" do
    it "still pairs a giro −X with the card +X even when a PayPal account exists" do
      # A PayPal account is present, but neither settlement leg faces PayPal Europe.
      create(:account, bank_connection: create(:bank_connection, :paypal, user: user),
        account_uid: "paypal", iban: nil, name: "PayPal", role_locked: true)
      out = leg(account: privat, amount: -300.00, creditor_iban: gemeinschaft.iban)
      inn = leg(account: gemeinschaft, amount: 300.00, debtor_iban: privat.iban)

      subject.match

      out.reload
      inn.reload
      expect(out.transfer_group_id).to be_present
      expect(out.transfer_group_id).to eq(inn.transfer_group_id)
      expect(out.transfer_counterpart_account_id).to eq(gemeinschaft.id)
      expect(inn.transfer_counterpart_account_id).to eq(privat.id)
    end
  end

  # Integration with the §4a exclusion: once marked, the funding leg's counterpart
  # is the PayPal account, so in_scope nets it out → no double-count, hidden from
  # the list (under both Familie and Privat, since PayPal is personal by default).
  describe "in_scope nets the marked conduit leg (no double-count)" do
    let(:paypal_bc) { create(:bank_connection, :paypal, user: user) }
    let!(:paypal) { create(:account, bank_connection: paypal_bc, account_uid: "paypal", iban: nil, name: "PayPal", role_locked: true) }

    def in_scope(scope, ids)
      return scope.none if ids.empty?

      scope.where(account_id: ids)
           .where("transfer_counterpart_account_id IS NULL OR transfer_counterpart_account_id NOT IN (?)", ids)
    end

    it "excludes the funding Lastschrift from the user's flows after matching (Familie + Privat)" do
      funding = leg(account: privat, amount: -188.95,
        creditor_name: "PayPal Europe S.a.r.l. et Cie S.C.A", creditor_iban: "LU89751000135104200E")
      purchase = leg(account: paypal, amount: -188.95, creditor_name: "TRMNL")

      subject.match

      # Familie = all accounts in scope → funding leg's counterpart (PayPal) in
      # scope → excluded; the PayPal purchase stays (counted once).
      familie_ids = user.accounts.pluck(:id)
      familie = in_scope(TransactionRecord.all, familie_ids)
      expect(familie).to include(purchase)
      expect(familie).not_to include(funding)

      # Privat = personal accounts (PayPal is personal) → still in scope → still excluded.
      privat_ids = user.accounts.personal.pluck(:id)
      expect(privat_ids).to include(paypal.id)
      privat_scope = in_scope(TransactionRecord.all, privat_ids)
      expect(privat_scope).not_to include(funding)
    end
  end

  # Trade Republic conduit: like PayPal, a one-legged same-sign transfer to the
  # user's TR ASSET account — but recognized by an EXACT match of the counterpart
  # IBAN to the TR account's OWN iban. TR's deposit IBAN is per-user and the
  # counterparty name is the user's own name, so the IBAN is the only signal.
  describe "Trade Republic conduit (one-legged transfer to the TR account)" do
    # The TR account carries its own cash/deposit IBAN. The balance-only scraper
    # can't read it, so it is set per user; here we seed it. role_locked so the
    # inferrer after_commit can't fight us.
    let(:tr_iban) { "DE23100123450185492701" }
    let!(:tr) do
      create(:account, bank_connection: create(:bank_connection, :trade_republic, user: user),
        account_uid: "trade_republic", iban: tr_iban, name: "Trade Republic", role_locked: true)
    end

    it "marks a giro→TR Sparplan deposit (debit to the TR IBAN) as a transfer to TR" do
      # The real shape: −10 from the giro, creditor IBAN = the user's TR cash IBAN,
      # creditor name = the user's OWN name (no "Trade Republic" string anywhere).
      deposit = leg(account: privat, amount: -10.00,
        creditor_name: "Eike Rackwitz", creditor_iban: tr_iban, remittance: "Testuberweisung")

      subject.match

      deposit.reload
      expect(deposit.transfer_counterpart_account_id).to eq(tr.id)
      expect(deposit.transfer_group_id).to be_present
    end

    it "marks a TR→giro withdrawal (credit from the TR IBAN) as a transfer to TR" do
      withdrawal = leg(account: privat, amount: 500.00,
        debtor_name: "Eike Rackwitz", debtor_iban: tr_iban, remittance: "Auszahlung")

      subject.match

      withdrawal.reload
      expect(withdrawal.transfer_counterpart_account_id).to eq(tr.id)
      expect(withdrawal.transfer_group_id).to be_present
    end

    it "does NOT touch a giro debit to a DIFFERENT IBAN (only the exact TR IBAN counts)" do
      other = leg(account: privat, amount: -10.00, creditor_name: "Eike Rackwitz",
        creditor_iban: "DE99999999999999999999", remittance: "woanders hin")

      subject.match

      other.reload
      expect(other.transfer_group_id).to be_nil
      expect(other.transfer_counterpart_account_id).to be_nil
    end

    it "does NOT touch the TR account's own rows" do
      own = leg(account: tr, amount: -10.00, creditor_iban: tr_iban)

      subject.match

      expect(own.reload.transfer_group_id).to be_nil
    end

    it "is idempotent — a second run keeps the same group_id" do
      deposit = leg(account: privat, amount: -10.00, creditor_iban: tr_iban, creditor_name: "Eike Rackwitz")

      subject.match
      group_id = deposit.reload.transfer_group_id
      expect(group_id).to be_present

      described_class.new(user).match

      expect(deposit.reload.transfer_group_id).to eq(group_id)
      expect(deposit.transfer_counterpart_account_id).to eq(tr.id)
    end

    it "preserves a user category on the deposit it marks (only the transfer FKs change)" do
      cat = create(:category, user: user)
      deposit = leg(account: privat, amount: -10.00, category: cat,
        creditor_iban: tr_iban, creditor_name: "Eike Rackwitz")

      subject.match

      deposit.reload
      expect(deposit.transfer_counterpart_account_id).to eq(tr.id)
      expect(deposit.category_id).to eq(cat.id)
    end

    # B1 GUARD (regression for the review blocker): a giro→TR deposit must not be
    # hijacked by the greedy +/− pairing. Before the fix, pair_new_legs ran first and
    # the −10 deposit (creditor_iban = the TR IBAN, an own IBAN) was "corroborated" on
    # its own, so it got paired with a coincidental unrelated +10 — silently swallowing
    # a real income. Now the conduit pass runs BEFORE pair_new_legs and claims the
    # deposit by its exact TR-IBAN signal, so the income stays a visible flow.
    it "does NOT let a coincidental unrelated +X of equal amount swallow the deposit" do
      deposit = leg(account: privat, amount: -10.00, creditor_iban: tr_iban, creditor_name: "Eike Rackwitz")
      income  = leg(account: gemeinschaft, amount: 10.00, debtor_name: "Katja Externa")

      subject.match

      deposit.reload
      income.reload
      expect(deposit.transfer_counterpart_account_id).to eq(tr.id)
      expect(income.transfer_group_id).to be_nil
      expect(income.transfer_counterpart_account_id).to be_nil
    end

    it "un-marks the one-legged conduit leg when the TR account is later deleted (S2)" do
      deposit = leg(account: privat, amount: -10.00, creditor_iban: tr_iban, creditor_name: "Eike Rackwitz")
      subject.match
      expect(deposit.reload.transfer_counterpart_account_id).to eq(tr.id)

      # Deleting the TR account nullifies transfer_counterpart_account_id (FK
      # on_delete: :nullify); the next run drops the orphaned group_id so the giro
      # leg becomes a real flow again rather than a phantom transfer forever.
      tr.destroy!

      described_class.new(user).match

      deposit.reload
      expect(deposit.transfer_counterpart_account_id).to be_nil
      expect(deposit.transfer_group_id).to be_nil
    end

    it "matches regardless of IBAN spacing/case on the leg (normalized on both sides)" do
      deposit = leg(account: privat, amount: -10.00, creditor_name: "Eike Rackwitz",
        creditor_iban: "de23 1001 2345 0185 4927 01")

      subject.match

      expect(deposit.reload.transfer_counterpart_account_id).to eq(tr.id)
    end
  end

  describe "Trade Republic conduit guard — TR account without an IBAN" do
    # TR account present but iban still nil (the deposit IBAN hasn't been set yet).
    let!(:tr) do
      create(:account, bank_connection: create(:bank_connection, :trade_republic, user: user),
        account_uid: "trade_republic", iban: nil, name: "Trade Republic", role_locked: true)
    end

    it "leaves a giro→TR deposit as a real flow until the TR IBAN is set" do
      deposit = leg(account: privat, amount: -10.00, creditor_name: "Eike Rackwitz",
        creditor_iban: "DE23100123450185492701", remittance: "Testuberweisung")

      subject.match

      deposit.reload
      expect(deposit.transfer_group_id).to be_nil
      expect(deposit.transfer_counterpart_account_id).to be_nil
    end
  end
end
