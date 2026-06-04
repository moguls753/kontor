FactoryBot.define do
  factory :easybank_credential do
    user
    username { "alice.banks" }
    password { "s3cret-pass" }

    trait :paired do
      last_paired_at { 1.day.ago }
    end
  end
end
