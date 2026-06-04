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
FactoryBot.define do
  factory :trade_republic_credential do
    user
    phone_number { "+4915112345678" }
    pin { "1234" }

    trait :paired do
      session_blob { Base64.strict_encode64("# Netscape HTTP Cookie File\n.traderepublic.com\tTRUE\t/\tTRUE\t0\tsession\ttoken\n") }
      last_paired_at { 1.day.ago }
    end
  end
end
