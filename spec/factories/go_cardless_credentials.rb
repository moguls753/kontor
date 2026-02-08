# == Schema Information
#
# Table name: go_cardless_credentials
#
#  id                 :integer          not null, primary key
#  access_expires_at  :datetime
#  access_token       :text
#  refresh_expires_at :datetime
#  refresh_token      :text
#  secret_key         :string           not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  secret_id          :string           not null
#  user_id            :integer          not null
#
# Indexes
#
#  index_go_cardless_credentials_on_user_id  (user_id) UNIQUE
#
# Foreign Keys
#
#  user_id  (user_id => users.id)
#
FactoryBot.define do
  factory :go_cardless_credential do
    user
    secret_id { SecureRandom.uuid }
    secret_key { SecureRandom.hex(32) }

    trait :with_token do
      access_token { SecureRandom.hex(32) }
      refresh_token { SecureRandom.hex(32) }
      access_expires_at { 1.day.from_now }
      refresh_expires_at { 30.days.from_now }
    end

    trait :expired_access do
      access_token { SecureRandom.hex(32) }
      refresh_token { SecureRandom.hex(32) }
      access_expires_at { 1.hour.ago }
      refresh_expires_at { 30.days.from_now }
    end

    trait :fully_expired do
      access_token { SecureRandom.hex(32) }
      refresh_token { SecureRandom.hex(32) }
      access_expires_at { 1.hour.ago }
      refresh_expires_at { 1.hour.ago }
    end
  end
end
