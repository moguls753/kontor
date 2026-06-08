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
FactoryBot.define do
  factory :merchant_alias do
    user
    raw_key { "spotify" }
    canonical_name { "Spotify" }
    merchant_type { "subscription" }
    source { "llm" }

    trait :deterministic do
      source { "deterministic" }
      merchant_type { nil }
    end
  end
end
