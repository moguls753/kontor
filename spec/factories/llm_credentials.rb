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
FactoryBot.define do
  factory :llm_credential do
    user
    base_url { "https://api.openai.com/v1" }
    api_key { "sk-test-#{SecureRandom.hex(16)}" }
    llm_model { "gpt-4o-mini" }
  end
end
