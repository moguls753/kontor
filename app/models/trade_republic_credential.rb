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
class TradeRepublicCredential < ApplicationRecord
  belongs_to :user

  # Phone + PIN are needed to pair; session_blob is the cookie jar returned by
  # the sidecar and refreshed on every balance fetch. None are ever exposed.
  encrypts :phone_number, :pin, :session_blob

  validates :phone_number, presence: true, format: { with: /\A\+\d{6,15}\z/ }
  validates :pin, presence: true, format: { with: /\A\d{4,8}\z/ }

  def configured?
    phone_number.present?
  end

  # Masked for display in settings — keeps the country code and last two digits.
  def phone_number_masked
    return nil if phone_number.blank?
    return phone_number if phone_number.length <= 5

    "#{phone_number[0, 3]}#{'•' * (phone_number.length - 5)}#{phone_number[-2..]}"
  end
end
