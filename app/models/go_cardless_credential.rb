# == Schema Information
#
# Table name: go_cardless_credentials
#
#  id                 :integer          not null, primary key
#  access_expires_at  :datetime
#  access_token       :text
#  refresh_expires_at :datetime
#  refresh_token      :text
#  secret_key         :string           not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  secret_id          :string           not null
#  user_id            :integer          not null
#
# Indexes
#
#  index_go_cardless_credentials_on_user_id  (user_id) UNIQUE
#
# Foreign Keys
#
#  user_id  (user_id => users.id)
#
class GoCardlessCredential < ApplicationRecord
  belongs_to :user

  encrypts :secret_id, :secret_key, :access_token, :refresh_token

  validates :secret_id, presence: true
  validates :secret_key, presence: true

  def access_expired?
    access_expires_at.nil? || access_expires_at <= Time.current
  end

  def refresh_valid?
    refresh_expires_at.present? && refresh_expires_at > Time.current
  end

  def ensure_valid_token!(client:)
    return unless access_expired?

    if refresh_valid?
      refresh!(client: client)
    else
      fetch_new_token!(client: client)
    end
  end

  def fetch_new_token!(client:)
    data = client.obtain_token(secret_id: secret_id, secret_key: secret_key)
    update!(
      access_token: data[:access],
      refresh_token: data[:refresh],
      access_expires_at: Time.current + data[:access_expires].to_i.seconds,
      refresh_expires_at: Time.current + data[:refresh_expires].to_i.seconds
    )
  end

  def refresh!(client:)
    data = client.refresh_token(refresh: refresh_token)
    update!(
      access_token: data[:access],
      access_expires_at: Time.current + data[:access_expires].to_i.seconds
    )
  end
end
