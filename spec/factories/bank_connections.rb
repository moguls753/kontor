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
FactoryBot.define do
  factory :bank_connection do
    user
    institution_id { "SPARKASSE_FREIBURG_DE" }
    institution_name { "Sparkasse Freiburg" }
    country_code { "DE" }
    status { "authorized" }
    provider { "enable_banking" }
    session_id { SecureRandom.uuid }
    valid_until { 180.days.from_now }

    trait :pending do
      status { "pending" }
      session_id { nil }
      valid_until { nil }
    end

    trait :expired do
      status { "expired" }
      valid_until { 1.day.ago }
    end

    trait :error do
      status { "error" }
      error_message { "Bank connection failed" }
    end

    trait :gocardless do
      provider { "gocardless" }
      session_id { nil }
      valid_until { nil }
      requisition_id { SecureRandom.uuid }
      institution_id { "TOMORROW_SOLDE1S" }
      institution_name { "Tomorrow" }
    end
  end
end
