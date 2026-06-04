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
class EasybankCredential < ApplicationRecord
  belongs_to :user

  # Username + password are the easybank online-banking login, replayed to the
  # network-isolated sidecar on every sync. Never exposed. last_paired_at lets us
  # tell an already device-paired profile from a fresh one, so we don't re-trigger
  # the interactive backfill mTAN unattended.
  encrypts :username, :password

  validates :username, presence: true
  validates :password, presence: true

  def configured?
    username.present?
  end

  # Masked for display in settings — keeps the first two characters, hides the
  # rest. Never reveals the full login.
  def username_masked
    return nil if username.blank?
    return "•" * username.length if username.length <= 2

    "#{username[0, 2]}#{'•' * (username.length - 2)}"
  end
end
