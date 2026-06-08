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
class MerchantAlias < ApplicationRecord
  belongs_to :user

  validates :raw_key, presence: true, uniqueness: { scope: :user_id }
  validates :canonical_name, presence: true
  normalizes :raw_key, with: ->(k) { k.to_s.strip.downcase }
end
