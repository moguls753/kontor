require "digest"

# == Schema Information
#
# Table name: recurring_series
#
#  id                :integer          not null, primary key
#  amount_max        :decimal(15, 2)
#  amount_min        :decimal(15, 2)
#  amount_variable   :boolean          default(FALSE), not null
#  cadence           :string           not null
#  cadence_days      :integer
#  canonical_name    :string           not null
#  confidence        :decimal(4, 3)    default(0.0), not null
#  currency          :string(3)        not null
#  direction         :string           not null
#  expected_amount   :decimal(15, 2)
#  fingerprint       :string           not null
#  first_seen_on     :date
#  last_seen_on      :date
#  merchant_type     :string
#  next_expected_on  :date
#  occurrences_count :integer          default(0), not null
#  status            :string           default("active"), not null
#  user_confirmed    :boolean          default(FALSE), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  category_id       :integer
#  user_id           :integer          not null
#
# Indexes
#
#  index_recurring_series_on_category_id              (category_id)
#  index_recurring_series_on_user_id                  (user_id)
#  index_recurring_series_on_user_id_and_fingerprint  (user_id,fingerprint)
#  index_recurring_series_on_user_id_and_status       (user_id,status)
#
# Foreign Keys
#
#  category_id  (category_id => categories.id)
#  user_id      (user_id => users.id)
#
class RecurringSeries < ApplicationRecord
  belongs_to :user
  belongs_to :category, optional: true
  has_many :transaction_records, dependent: :nullify

  DIRECTIONS = %w[inflow outflow].freeze
  CADENCES   = %w[weekly biweekly monthly quarterly yearly irregular].freeze
  STATUSES   = %w[active ended dismissed].freeze

  # Consumption-type merchants (supermarkets, shops, transport tickets) coincidentally
  # look recurring but are NOT contracts/subscriptions. They are hidden from the
  # "Wiederkehrend" page by default (kept in the DB for a future Statistics module).
  CONSUMPTION_TYPES = %w[shopping groceries transport].freeze

  # §5a — category name that flags a *savings* contribution. Counts as "Sparen" ONLY in
  # combination with a saving-destination/shared account (the Mila-fix); the name alone
  # never moves a series into the savings bucket.
  SAVINGS_CATEGORY_NAME = "Sparen".freeze

  FLOW_BUCKETS = %w[contract income savings transfer].freeze

  validates :canonical_name, :currency, :fingerprint, presence: true
  validates :direction, inclusion: { in: DIRECTIONS }
  validates :cadence,   inclusion: { in: CADENCES }
  validates :status,    inclusion: { in: STATUSES }
  validate  :category_belongs_to_user

  before_save :sync_fingerprint

  scope :active,    -> { where(status: "active") }
  scope :outflows,  -> { where(direction: "outflow") }
  scope :inflows,   -> { where(direction: "inflow") }

  # #9 — single source of truth for the series fingerprint. Both the detector and
  # the rename-on-save callback derive the fingerprint here so name and fingerprint
  # can never desync. Formula copied verbatim from the detector → byte-identical
  # for existing rows/specs.
  def self.fingerprint_for(direction, currency, canonical_name)
    Digest::SHA256.hexdigest("#{direction}|#{currency}|#{canonical_name.to_s.downcase.strip}")[0, 16]
  end

  # §5a — derive which of the four recurring "Töpfe" a series belongs to, from existing
  # signals only (no guessing). The order matters: "Sparen" wins over a plain transfer,
  # and the category "Sparen" ALONE never qualifies — it only counts IN COMBINATION with a
  # saving-destination/shared account (the Mila-fix). Returns one of FLOW_BUCKETS.
  #
  # `members` may be supplied (preloaded, with :account & :transfer_counterpart_account) to
  # avoid an N+1 in the index; otherwise it falls back to the association.
  def flow_bucket(members: nil)
    members ||= transaction_records.includes(:account, :transfer_counterpart_account).to_a

    if savings?(members)
      "savings"
    elsif members.any?(&:internal_transfer?)
      # "transfer" is derived from the members' LIVE transfer_group_id — never from a
      # sticky merchant_type == "transfer". A series first matched as a transfer and
      # later unmatched (legs lose their transfer_group_id) becomes a real flow again,
      # so a sticky column must not hide it as a transfer forever.
      "transfer"
    elsif direction == "inflow"
      "income"
    else
      "contract"
    end
  end

  # §5a step 1 — a series is "Sparen" when ANY of:
  #   • a member is a matched internal transfer into a saving_destination? account, OR
  #   • merchant_type == "investment" (external broker, e.g. Scalable — best-effort/LLM), OR
  #   • a member flows INTO a shared/saving_destination? account AND the category is "Sparen".
  # The third leg requires BOTH the destination AND the category → Mila (external person,
  # category "Sparen", no saving destination) stays OUT.
  def savings?(members = nil)
    return true if merchant_type == "investment"

    members ||= transaction_records.includes(:account, :transfer_counterpart_account).to_a
    return true if members.any? { |m| m.transfer_counterpart_account&.saving_destination? }

    savings_category? && members.any? { |m| flows_into_savings_destination?(m) }
  end

  private

  def savings_category?
    category&.name.to_s.casecmp?(SAVINGS_CATEGORY_NAME)
  end

  # A member lands in a saving/shared destination: either it is a credit booked on such an
  # account (Katja's "Ansparen" into the Gemeinschaft), or it is sent to one (counterpart).
  def flows_into_savings_destination?(member)
    cp = member.transfer_counterpart_account
    return true if cp&.saving_destination? || cp&.shared?

    acct = member.account
    member.amount.to_d.positive? && (acct&.saving_destination? || acct&.shared?)
  end

  # #9 — auto-recompute fingerprint whenever the identifying fields are present, so a
  # controller renaming canonical_name (or a canonical upgrade) can't leave fingerprint
  # stale. Recomputes to the same value when nothing relevant changed.
  def sync_fingerprint
    return if direction.blank? || currency.blank? || canonical_name.blank?

    self.fingerprint = self.class.fingerprint_for(direction, currency, canonical_name)
  end

  # Prevent attaching another user's category (cross-user data leak).
  def category_belongs_to_user
    return if category_id.blank?
    return if category && category.user_id == user_id

    errors.add(:category_id, "must belong to the same user")
  end
end
