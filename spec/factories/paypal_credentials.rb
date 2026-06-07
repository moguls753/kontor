# == Schema Information
#
# Table name: paypal_credentials
#
#  id         :integer          not null, primary key
#  password   :text
#  username   :text
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :integer          not null
#
# Indexes
#
#  index_paypal_credentials_on_user_id  (user_id) UNIQUE
#
# Foreign Keys
#
#  user_id  (user_id => users.id)
#
FactoryBot.define do
  factory :paypal_credential do
    user
    username { "alice@example.com" }
    password { "s3cret-pass" }
  end
end
