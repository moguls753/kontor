# == Schema Information
#
# Table name: trade_republic_credentials
#
#  id             :integer          not null, primary key
#  last_paired_at :datetime
#  phone_number   :text
#  pin            :text
#  session_blob   :text
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  user_id        :integer          not null
#
# Indexes
#
#  index_trade_republic_credentials_on_user_id  (user_id) UNIQUE
#
# Foreign Keys
#
#  user_id  (user_id => users.id)
#
require "rails_helper"

RSpec.describe TradeRepublicCredential, type: :model do
  it "is valid with a phone number and PIN" do
    expect(build(:trade_republic_credential)).to be_valid
  end

  it "validates the phone number format" do
    expect(build(:trade_republic_credential, phone_number: "0151")).not_to be_valid
    expect(build(:trade_republic_credential, phone_number: "+4915112345678")).to be_valid
  end

  it "validates the PIN format" do
    expect(build(:trade_republic_credential, pin: "abcd")).not_to be_valid
    expect(build(:trade_republic_credential, pin: "1234")).to be_valid
  end

  it "allows only one credential per user" do
    user = create(:user)
    create(:trade_republic_credential, user: user)
    duplicate = build(:trade_republic_credential, user: user)
    expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "encrypts the PIN at rest" do
    credential = create(:trade_republic_credential)
    raw_value = ActiveRecord::Base.connection.select_value(
      "SELECT pin FROM trade_republic_credentials WHERE id = ?", "SQL", [ credential.id ]
    )
    expect(raw_value).not_to eq(credential.pin)
    expect(raw_value).not_to include("1234")
  end

  it "masks the phone number keeping the country code and last two digits" do
    masked = build(:trade_republic_credential, phone_number: "+4915112345678").phone_number_masked
    expect(masked).to start_with("+49")
    expect(masked).to end_with("78")
    expect(masked).to include("•")
    expect(masked).not_to include("15112345678")
  end
end
