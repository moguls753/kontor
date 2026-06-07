# == Schema Information
#
# Table name: easybank_credentials
#
#  id             :integer          not null, primary key
#  last_paired_at :datetime
#  password       :text
#  username       :text
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  user_id        :integer          not null
#
# Indexes
#
#  index_easybank_credentials_on_user_id  (user_id) UNIQUE
#
# Foreign Keys
#
#  user_id  (user_id => users.id)
#
FactoryBot.define do
  factory :easybank_credential do
    user
    username { "alice.banks" }
    password { "s3cret-pass" }

    trait :paired do
      last_paired_at { 1.day.ago }
    end
  end
end
