# == Schema Information
#
# Table name: llm_credentials
#
#  id         :integer          not null, primary key
#  api_key    :text
#  base_url   :string           not null
#  llm_model  :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :integer          not null
#
# Indexes
#
#  index_llm_credentials_on_user_id  (user_id) UNIQUE
#
# Foreign Keys
#
#  user_id  (user_id => users.id)
#
class LlmCredential < ApplicationRecord
  belongs_to :user

  encrypts :api_key

  normalizes :api_key, with: ->(v) { v.presence }

  validates :base_url, presence: true, format: { with: /\Ahttps?:\/\/\S+\z/i, message: "must start with http:// or https://" }
  validates :llm_model, presence: true
end
