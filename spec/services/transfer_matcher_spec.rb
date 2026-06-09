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
end
