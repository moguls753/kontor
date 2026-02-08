# == Schema Information
#
# Table name: enable_banking_credentials
#
#  id              :integer          not null, primary key
#  private_key_pem :text             not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  app_id          :string           not null
#  user_id         :integer          not null
#
# Indexes
#
#  index_enable_banking_credentials_on_user_id  (user_id) UNIQUE
#
# Foreign Keys
#
#  user_id  (user_id => users.id)
#
require "rails_helper"

RSpec.describe EnableBankingCredential, type: :model do
  it "is valid with app_id and private_key_pem" do
    expect(build(:enable_banking_credential)).to be_valid
  end

  it "requires app_id" do
    expect(build(:enable_banking_credential, app_id: nil)).not_to be_valid
  end

  it "requires private_key_pem" do
    expect(build(:enable_banking_credential, private_key_pem: nil)).not_to be_valid
  end

  it "allows only one credential per user" do
    user = create(:user)
    create(:enable_banking_credential, user: user)
    duplicate = build(:enable_banking_credential, user: user)
    expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "encrypts private_key_pem" do
    credential = create(:enable_banking_credential)
    raw_value = ActiveRecord::Base.connection.select_value(
      "SELECT private_key_pem FROM enable_banking_credentials WHERE id = ?", "SQL", [ credential.id ]
    )
    expect(raw_value).not_to include("BEGIN RSA PRIVATE KEY")
  end
end
