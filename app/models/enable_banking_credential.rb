# == Schema Information
#
# Table name: enable_banking_credentials
#
#  id              :integer          not null, primary key
#  private_key_pem :text             not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  app_id          :string           not null
#  user_id         :integer          not null
#
# Indexes
#
#  index_enable_banking_credentials_on_user_id  (user_id) UNIQUE
#
# Foreign Keys
#
#  user_id  (user_id => users.id)
#
class EnableBankingCredential < ApplicationRecord
  belongs_to :user

  encrypts :private_key_pem

  validates :app_id, presence: true
  validates :private_key_pem, presence: true
end
