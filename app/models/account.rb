# == Schema Information
#
# Table name: accounts
#
#  id                  :integer          not null, primary key
#  account_type        :string
#  account_uid         :string           not null
#  available_credit    :decimal(15, 2)
#  balance_amount      :decimal(15, 2)
#  balance_type        :string
#  balance_updated_at  :datetime
#  credit_limit        :decimal(15, 2)
#  currency            :string(3)        default("EUR")
#  iban                :string
#  identification_hash :string
#  last_synced_at      :datetime
#  name                :string
#  role                :string
#  role_locked         :boolean          default(FALSE), not null
#  shared              :boolean          default(FALSE), not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  bank_connection_id  :integer          not null
#
# Indexes
#
#  index_accounts_on_account_uid          (account_uid)
#  index_accounts_on_bank_connection_id   (bank_connection_id)
#  index_accounts_on_identification_hash  (identification_hash)
#
# Foreign Keys
#
#  bank_connection_id  (bank_connection_id => bank_connections.id)
#
class Account < ApplicationRecord
  ROLES = %w[giro sparkonto investment kreditkarte zahlung sonstiges].freeze

  belongs_to :bank_connection
  has_many :transaction_records, dependent: :destroy
  has_many :balance_snapshots, dependent: :destroy
  has_one :user, through: :bank_connection

  validates :account_uid, presence: true
  validates :currency, presence: true
  validates :role, inclusion: { in: ROLES }, allow_nil: true

  scope :shared,   -> { where(shared: true) }
  scope :personal, -> { where(shared: false) } # NOT private_ (Ruby keyword trap)

  # Infer a role/shared default when an account is created or when the signals it
  # reads (name / account_type) change during sync — e.g. GoCardless fills in the
  # owner name later. Never runs against a user-locked account (the inferrer
  # guards on role_locked). after_commit so the row (and its bank_connection) is
  # fully persisted before we read the provider.
  after_commit :infer_role, on: %i[create update]

  def display_name
    name.presence || iban.presence || "Account #{id}"
  end

  private

  # Run the inferrer on create, or when a signal it reads changed. The inferrer
  # itself persists role/shared via update!, so we skip when only role/shared/
  # role_locked changed to avoid a pointless re-run loop.
  def infer_role
    return if role_locked?
    return unless previously_new_record? ||
                  saved_change_to_name? ||
                  saved_change_to_account_type?

    AccountRoleInferrer.new(self).infer!
  end
end
