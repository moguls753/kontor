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
require "rails_helper"

RSpec.describe BankConnection, type: :model do
  it "is valid with required attributes" do
    expect(build(:bank_connection)).to be_valid
  end

  it "requires institution_id" do
    expect(build(:bank_connection, institution_id: nil)).not_to be_valid
  end

  it "rejects invalid status" do
    expect { build(:bank_connection, status: "invalid") }.to raise_error(ArgumentError)
  end

  it "knows when expired" do
    expect(build(:bank_connection, status: "expired")).to be_expired
  end
end
