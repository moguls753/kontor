# == Schema Information
#
# Table name: merchant_aliases
#
#  id             :integer          not null, primary key
#  canonical_name :string           not null
#  merchant_type  :string
#  raw_key        :string           not null
#  source         :string           default("llm"), not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  user_id        :integer          not null
#
# Indexes
#
#  index_merchant_aliases_on_canonical_name       (canonical_name)
#  index_merchant_aliases_on_user_id              (user_id)
#  index_merchant_aliases_on_user_id_and_raw_key  (user_id,raw_key) UNIQUE
#
# Foreign Keys
#
#  user_id  (user_id => users.id)
#
require "rails_helper"

RSpec.describe MerchantAlias, type: :model do
  it "has a valid factory" do
    expect(build(:merchant_alias)).to be_valid
  end

  it "requires raw_key and canonical_name" do
    expect(build(:merchant_alias, raw_key: nil)).not_to be_valid
    expect(build(:merchant_alias, canonical_name: nil)).not_to be_valid
  end

  it "belongs to a user" do
    expect(build(:merchant_alias, user: nil)).not_to be_valid
  end

  it "enforces uniqueness of raw_key per user" do
    existing = create(:merchant_alias, raw_key: "spotify")
    expect(build(:merchant_alias, user: existing.user, raw_key: "spotify")).not_to be_valid
    # a different user may reuse the same raw_key
    expect(build(:merchant_alias, user: create(:user), raw_key: "spotify")).to be_valid
  end

  it "normalizes raw_key to stripped downcase" do
    a = create(:merchant_alias, raw_key: "  SpoTiFy  ", canonical_name: "Spotify")
    expect(a.raw_key).to eq("spotify")
  end

  it "maps to the merchant_aliases table" do
    expect(described_class.table_name).to eq("merchant_aliases")
  end
end
