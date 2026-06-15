# == Schema Information
#
# Table name: recurring_series
#
#  id                :integer          not null, primary key
#  amount_max        :decimal(15, 2)
#  amount_min        :decimal(15, 2)
#  amount_variable   :boolean          default(FALSE), not null
#  cadence           :string           not null
#  cadence_days      :integer
#  canonical_name    :string           not null
#  confidence        :decimal(4, 3)    default(0.0), not null
#  currency          :string(3)        not null
#  direction         :string           not null
#  expected_amount   :decimal(15, 2)
#  fingerprint       :string           not null
#  first_seen_on     :date
#  last_seen_on      :date
#  merchant_type     :string
#  next_expected_on  :date
#  occurrences_count :integer          default(0), not null
#  status            :string           default("active"), not null
#  user_confirmed    :boolean          default(FALSE), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  category_id       :integer
#  user_id           :integer          not null
#
# Indexes
#
#  index_recurring_series_on_category_id              (category_id)
#  index_recurring_series_on_user_id                  (user_id)
#  index_recurring_series_on_user_id_and_fingerprint  (user_id,fingerprint)
#  index_recurring_series_on_user_id_and_status       (user_id,status)
#
# Foreign Keys
#
#  category_id  (category_id => categories.id)
#  user_id      (user_id => users.id)
#
require "rails_helper"

RSpec.describe RecurringSeries, type: :model do
  it "has a valid factory" do
    expect(build(:recurring_series)).to be_valid
  end

  it "requires canonical_name, currency, fingerprint" do
    expect(build(:recurring_series, canonical_name: nil)).not_to be_valid
    expect(build(:recurring_series, currency: nil)).not_to be_valid
    expect(build(:recurring_series, fingerprint: nil)).not_to be_valid
  end

  it "validates direction inclusion" do
    expect(build(:recurring_series, direction: "sideways")).not_to be_valid
    expect(build(:recurring_series, direction: "inflow")).to be_valid
  end

  it "validates cadence inclusion" do
    expect(build(:recurring_series, cadence: "hourly")).not_to be_valid
    expect(build(:recurring_series, cadence: "yearly")).to be_valid
  end

  it "validates status inclusion" do
    expect(build(:recurring_series, status: "paused")).not_to be_valid
    expect(build(:recurring_series, status: "ended")).to be_valid
  end

  it "scopes active, outflows, inflows" do
    a = create(:recurring_series, status: "active", direction: "outflow")
    create(:recurring_series, status: "dismissed", direction: "outflow")
    inflow = create(:recurring_series, :inflow)

    expect(described_class.active).to include(a)
    expect(described_class.active.map(&:status).uniq).to eq([ "active" ])
    expect(described_class.outflows).to include(a)
    expect(described_class.inflows).to include(inflow)
  end

  it "resolves to the recurring_series table (uncountable inflection)" do
    expect(described_class.table_name).to eq("recurring_series")
  end

  it "nullifies member links on destroy" do
    bc = create(:bank_connection)
    account = create(:account, bank_connection: bc)
    series = create(:recurring_series, user: bc.user)
    tx = create(:transaction_record, account: account, recurring_series: series)

    series.destroy
    expect(tx.reload.recurring_series_id).to be_nil
  end

  # with_member_in: shared "≥1 in-scope member (or no members)" filter, keyed on
  # account MEMBERSHIP only (NOT the §4a net-zero exclusion). Used by both the
  # recurring index and the statistics forecast (A6).
  describe ".with_member_in" do
    let(:bc) { create(:bank_connection) }
    let(:user) { bc.user }
    let(:personal) { create(:account, bank_connection: bc, shared: false) }
    let(:shared)   { create(:account, bank_connection: bc, shared: true) }

    it "keeps a series with a member booked on an in-scope account" do
      s = create(:recurring_series, user: user, canonical_name: "On Personal")
      create(:transaction_record, account: personal, recurring_series: s, amount: -12)

      expect(described_class.with_member_in([ personal.id ])).to include(s)
    end

    it "drops a series whose members are all out of scope" do
      s = create(:recurring_series, user: user, canonical_name: "On Shared")
      create(:transaction_record, account: shared, recurring_series: s, amount: -15)

      expect(described_class.with_member_in([ personal.id ])).not_to include(s)
    end

    it "drops a series that has no members at all (can't be attributed to a scope)" do
      s = create(:recurring_series, user: user, canonical_name: "No Members")

      expect(described_class.with_member_in([ personal.id ])).not_to include(s)
    end

    # A personal→personal transfer has BOTH legs in scope; keying on membership (not
    # the §4a net-zero exclusion) keeps the series visible (it would otherwise have
    # zero in-scope members and vanish).
    it "keeps a personal→personal transfer series (membership, not net-zero, decides)" do
      other = create(:account, bank_connection: bc, shared: false)
      s = create(:recurring_series, user: user, direction: "outflow", canonical_name: "Sparplan")
      create(:transaction_record, account: personal, recurring_series: s, amount: -250,
        transfer_group_id: "tg-priv", transfer_counterpart_account: other)

      expect(described_class.with_member_in([ personal.id, other.id ])).to include(s)
    end

    it "returns none for empty ids" do
      create(:recurring_series, user: user)
      expect(described_class.with_member_in([])).to eq([])
      expect(described_class.with_member_in(nil)).to eq([])
    end
  end

  # flow_bucket: three töpfe from UNAMBIGUOUS signals only — direction + own-account
  # membership. No "is this savings?" guessing (dropped). expense / income / transfer.
  describe "#flow_bucket" do
    let(:bc) { create(:bank_connection) }
    let(:user) { bc.user }
    let(:giro)  { create(:account, bank_connection: bc, role: "giro", role_locked: true) }
    let(:tr)    { create(:account, bank_connection: bc, role: "investment", role_locked: true) }

    it "classifies a matched internal transfer (any destination) as a transfer" do
      # Whatever the destination — investment, shared, plain giro — a matched own-account
      # move is a net-zero transfer. No savings special-case.
      series = create(:recurring_series, user: user, direction: "outflow", canonical_name: "TR")
      create(:transaction_record, account: giro, recurring_series: series, amount: -200,
        transfer_group_id: "g1", transfer_counterpart_account: tr)

      expect(series.flow_bucket).to eq("transfer")
    end

    it "classifies an external outflow (incl. savings plans like Scalable) as an expense" do
      # Scalable is a recurring outgoing to an EXTERNAL party — it's an expense, not a
      # special savings bucket. The user knows it's their savings; the system doesn't guess.
      series = create(:recurring_series, user: user, direction: "outflow", canonical_name: "Scalable Capital")
      create(:transaction_record, account: giro, recurring_series: series, amount: -150)

      expect(series.flow_bucket).to eq("expense")
    end

    it "classifies an external inflow as income" do
      series = create(:recurring_series, user: user, direction: "inflow", canonical_name: "Gehalt")
      create(:transaction_record, account: giro, recurring_series: series, amount: 2500)

      expect(series.flow_bucket).to eq("income")
    end

    # "transfer" is derived from the members' LIVE transfer_group_id, not a sticky
    # merchant_type == "transfer". A series whose legs are no longer matched must NOT stay
    # hidden as a transfer forever — it falls back to its directional flow.
    it "does NOT treat a sticky merchant_type=transfer as a transfer once its legs are unmatched" do
      series = create(:recurring_series, user: user, direction: "outflow",
        merchant_type: "transfer", canonical_name: "Was a transfer")
      create(:transaction_record, account: giro, recurring_series: series, amount: -42,
        transfer_group_id: nil, transfer_counterpart_account: nil)

      expect(series.flow_bucket).to eq("expense")
    end

    it "treats a cross-scope transfer as an expense when scope_ids exclude the counterpart" do
      shared = create(:account, bank_connection: bc, shared: true)
      series = create(:recurring_series, user: user, direction: "outflow", canonical_name: "Mietanteil")
      create(:transaction_record, account: giro, recurring_series: series, amount: -445,
        transfer_group_id: "g-rent", transfer_counterpart_account: shared)

      expect(series.flow_bucket).to eq("transfer")                          # Familie (unscoped)
      expect(series.flow_bucket(scope_ids: [ giro.id ])).to eq("expense")   # Privat: counterpart out of scope
      expect(series.flow_bucket(scope_ids: [ giro.id, shared.id ])).to eq("transfer") # both in scope
    end
  end
end
