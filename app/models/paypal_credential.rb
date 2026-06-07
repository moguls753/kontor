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
class PaypalCredential < ApplicationRecord
  belongs_to :user

  # Username + password are the PayPal web login, replayed to the
  # network-isolated paypal-scraper sidecar on every manual sync. Never exposed.
  encrypts :username, :password

  validates :username, presence: true
  validates :password, presence: true

  def configured?
    username.present?
  end

  # Masked for display in settings — keeps the first two characters, hides the
  # rest. Never reveals the full login. Mirrors EasybankCredential#username_masked.
  def username_masked
    return nil if username.blank?
    return "•" * username.length if username.length <= 2

    "#{username[0, 2]}#{'•' * (username.length - 2)}"
  end
end
