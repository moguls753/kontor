# == Schema Information
#
# Table name: llm_credentials
#
#  id         :integer          not null, primary key
#  api_key    :text
#  base_url   :string           not null
#  llm_model  :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :integer          not null
#
# Indexes
#
#  index_llm_credentials_on_user_id  (user_id) UNIQUE
#
# Foreign Keys
#
#  user_id  (user_id => users.id)
#
require "rails_helper"

RSpec.describe LlmCredential, type: :model do
  it "is valid with base_url, llm_model, and api_key" do
    expect(build(:llm_credential)).to be_valid
  end

  it "is valid without api_key" do
    expect(build(:llm_credential, api_key: nil)).to be_valid
  end

  it "requires base_url" do
    expect(build(:llm_credential, base_url: nil)).not_to be_valid
  end

  it "requires llm_model" do
    expect(build(:llm_credential, llm_model: nil)).not_to be_valid
  end

  it "requires base_url to start with http:// or https://" do
    expect(build(:llm_credential, base_url: "ftp://example.com")).not_to be_valid
    expect(build(:llm_credential, base_url: "http://localhost:1234/v1")).to be_valid
    expect(build(:llm_credential, base_url: "https://api.openai.com/v1")).to be_valid
  end

  it "allows only one credential per user" do
    user = create(:user)
    create(:llm_credential, user: user)
    duplicate = build(:llm_credential, user: user)
    expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "encrypts api_key" do
    credential = create(:llm_credential)
    raw_value = ActiveRecord::Base.connection.select_value(
      "SELECT api_key FROM llm_credentials WHERE id = ?", "SQL", [ credential.id ]
    )
    expect(raw_value).not_to include("sk-test-")
  end
end
