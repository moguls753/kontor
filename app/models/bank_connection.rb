# == Schema Information
#
# Table name: bank_connections
#
#  id               :integer          not null, primary key
#  country_code     :string(2)
#  error_message    :text
#  institution_name :string
#  last_synced_at   :datetime
#  link             :string
#  provider         :string           default("enable_banking"), not null
#  status           :string           default("pending"), not null
#  valid_until      :datetime
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  authorization_id :string
#  institution_id   :string           not null
#  requisition_id   :string
#  session_id       :string
#  user_id          :integer          not null
#
# Indexes
#
#  index_bank_connections_on_session_id                  (session_id) UNIQUE
#  index_bank_connections_on_user_id                     (user_id)
#  index_bank_connections_on_user_id_and_institution_id  (user_id,institution_id)
#
# Foreign Keys
#
#  user_id  (user_id => users.id)
#
class BankConnection < ApplicationRecord
  belongs_to :user
  has_many :accounts, dependent: :destroy

  enum :provider, { enable_banking: "enable_banking", gocardless: "gocardless" }
  enum :status, { pending: "pending", authorized: "authorized", expired: "expired", error: "error" }

  validates :institution_id, presence: true

  scope :active, -> { authorized.where("valid_until IS NULL OR valid_until > ?", Time.current) }
end
