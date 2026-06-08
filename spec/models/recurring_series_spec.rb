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
end
