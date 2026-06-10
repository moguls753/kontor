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

  FLOW_BUCKETS = %w[expense income transfer].freeze

  validates :canonical_name, :currency, :fingerprint, presence: true
  validates :direction, inclusion: { in: DIRECTIONS }
  validates :cadence,   inclusion: { in: CADENCES }
  validates :status,    inclusion: { in: STATUSES }
  validate  :category_belongs_to_user

  before_save :sync_fingerprint

  scope :active,    -> { where(status: "active") }
  scope :outflows,  -> { where(direction: "outflow") }
  scope :inflows,   -> { where(direction: "inflow") }

  # §4b / A6 — series visible under a given account scope: keep a series that has
  # ≥1 member booked on one of `account_ids`, OR has no members at all (nothing to
  # place out of scope). Keyed on account MEMBERSHIP ONLY, NOT the §4a in_scope
  # net-zero exclusion: a personal→personal transfer has BOTH legs in scope, so
  # the net-zero rule would leave it zero in-scope members and wrongly hide the
  # whole series — membership keeps it visible. Empty ids → none. Subqueries (not
  # plucked arrays) so empty results never produce invalid `IN ()` SQL.
  scope :with_member_in, ->(account_ids) {
    return none if account_ids.blank?

    in_scope_series = TransactionRecord.where(account_id: account_ids)
                                       .where.not(recurring_series_id: nil)
                                       .select(:recurring_series_id)
    any_member = TransactionRecord.where.not(recurring_series_id: nil)
                                  .select(:recurring_series_id)
    where(
      "recurring_series.id IN (#{in_scope_series.to_sql}) " \
      "OR recurring_series.id NOT IN (#{any_member.to_sql})"
    )
  }

  # #9 — single source of truth for the series fingerprint. Both the detector and
  # the rename-on-save callback derive the fingerprint here so name and fingerprint
  # can never desync. Formula copied verbatim from the detector → byte-identical
  # for existing rows/specs.
  def self.fingerprint_for(direction, currency, canonical_name)
    Digest::SHA256.hexdigest("#{direction}|#{currency}|#{canonical_name.to_s.downcase.strip}")[0, 16]
  end

  # Derive which of the three recurring "Töpfe" a series belongs to, from UNAMBIGUOUS
  # signals only — direction and whether it moves between the user's OWN accounts. No
  # "is this savings?" guessing (that classification was fuzzy: Scalable, Mila and own
  # Ansparen all defied a clean rule, so it was dropped). Returns one of FLOW_BUCKETS:
  #   • transfer — a matched internal transfer (live transfer_group_id) whose counterpart is
  #     in scope, i.e. a net-zero move between own in-scope accounts. Derived from the LIVE
  #     link, never a sticky merchant_type. Scope-aware: under the Privat lens a transfer to
  #     the out-of-scope joint account is NOT net-zero → falls through to a real flow (scope_ids).
  #   • income   — money coming in (inflow).
  #   • expense  — money going out (everything else: contracts, subscriptions, savings plans).
  #
  # `members` may be supplied (preloaded) to avoid an N+1; flow_bucket reads only their
  # transfer_group_id + transfer_counterpart_account_id FK columns (never the association
  # object), so preloading the members alone suffices. Otherwise it falls back to the association.
  def flow_bucket(members: nil, scope_ids: nil)
    members ||= transaction_records.to_a

    # A matched transfer is a net-zero "Umbuchung" only when its counterpart account is ALSO
    # in scope (mirrors ScopedAccounts#in_scope §4a). scope_ids nil (Familie / unscoped) →
    # any matched transfer counts (unchanged). Under Privat a transfer to the out-of-scope
    # joint account has its counterpart excluded → not net-zero → falls through to expense,
    # exactly as the dashboard/statistics treat it.
    net_zero_transfer = members.any? do |m|
      next false if m.transfer_group_id.blank?

      scope_ids.nil? || (m.transfer_counterpart_account_id.present? && scope_ids.include?(m.transfer_counterpart_account_id))
    end

    if net_zero_transfer
      "transfer"
    elsif direction == "inflow"
      "income"
    else
      "expense"
    end
  end

  private

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
