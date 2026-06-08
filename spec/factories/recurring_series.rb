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
FactoryBot.define do
  factory :recurring_series do
    user
    canonical_name { "Spotify" }
    direction { "outflow" }
    cadence { "monthly" }
    cadence_days { 30 }
    currency { "EUR" }
    expected_amount { -12.99 }
    amount_variable { false }
    amount_min { -12.99 }
    amount_max { -12.99 }
    confidence { 0.75 }
    status { "active" }
    occurrences_count { 4 }
    first_seen_on { Date.current - 120 }
    last_seen_on { Date.current - 1 }
    next_expected_on { Date.current + 29 }
    # mirror RecurringDetector#fingerprint = SHA256("dir|cur|canonical.downcase.strip")[0,16]
    fingerprint do
      Digest::SHA256.hexdigest("#{direction}|#{currency}|#{canonical_name.to_s.downcase.strip}")[0, 16]
    end

    trait :monthly do
      cadence { "monthly" }
      cadence_days { 30 }
    end

    trait :weekly do
      cadence { "weekly" }
      cadence_days { 7 }
      next_expected_on { Date.current + 6 }
    end

    trait :inflow do
      direction { "inflow" }
      canonical_name { "Arbeitgeber" }
      expected_amount { 2500.00 }
      amount_min { 2500.00 }
      amount_max { 2500.00 }
    end

    trait :dismissed do
      status { "dismissed" }
    end
  end
end
