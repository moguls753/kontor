# == Schema Information
#
# Table name: easybank_credentials
#
#  id             :integer          not null, primary key
#  last_paired_at :datetime
#  password       :text
#  username       :text
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  user_id        :integer          not null
#
# Indexes
#
#  index_easybank_credentials_on_user_id  (user_id) UNIQUE
#
# Foreign Keys
#
#  user_id  (user_id => users.id)
#
require "rails_helper"

RSpec.describe EasybankCredential, type: :model do
  it "is valid with a username and password" do
    expect(build(:easybank_credential)).to be_valid
  end

  it "requires a username" do
    expect(build(:easybank_credential, username: nil)).not_to be_valid
  end

  it "requires a password" do
    expect(build(:easybank_credential, password: nil)).not_to be_valid
  end

  it "allows only one credential per user" do
    user = create(:user)
    create(:easybank_credential, user: user)
    duplicate = build(:easybank_credential, user: user)
    expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "encrypts the password at rest" do
    credential = create(:easybank_credential, password: "s3cret-pass")
    raw_value = ActiveRecord::Base.connection.select_value(
      "SELECT password FROM easybank_credentials WHERE id = ?", "SQL", [ credential.id ]
    )
    expect(raw_value).not_to eq(credential.password)
    expect(raw_value).not_to include("s3cret-pass")
  end

  it "encrypts the username at rest" do
    credential = create(:easybank_credential, username: "alice.banks")
    raw_value = ActiveRecord::Base.connection.select_value(
      "SELECT username FROM easybank_credentials WHERE id = ?", "SQL", [ credential.id ]
    )
    expect(raw_value).not_to include("alice.banks")
  end

  it "masks the username keeping only the first two characters" do
    masked = build(:easybank_credential, username: "alice.banks").username_masked
    expect(masked).to start_with("al")
    expect(masked).to include("•")
    expect(masked).not_to include("alice.banks")
  end
end
