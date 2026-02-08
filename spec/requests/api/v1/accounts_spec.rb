require "rails_helper"

RSpec.describe "Api::V1::Accounts", type: :request do
  let(:user) { create(:user, password: "password123") }
  before { post session_path, params: { email_address: user.email_address, password: "password123" }, as: :json }

  it "lists accounts with bank connection info" do
    bc = create(:bank_connection, user: user)
    account = create(:account, bank_connection: bc, balance_amount: 1234.56)

    get api_v1_accounts_path, as: :json
    expect(response).to have_http_status(:ok)
    body = response.parsed_body.first
    expect(body["balance_amount"]).to eq("1234.56")
    expect(body["bank_connection"]["institution_name"]).to eq(bc.institution_name)
  end

  it "scopes to current user" do
    create(:account, bank_connection: create(:bank_connection, user: create(:user)))
    get api_v1_accounts_path, as: :json
    expect(response.parsed_body).to be_empty
  end

  it "renames an account" do
    bc = create(:bank_connection, user: user)
    account = create(:account, bank_connection: bc, name: "Old Name")

    patch api_v1_account_path(account), params: { name: "My Checking" }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["name"]).to eq("My Checking")
    expect(account.reload.name).to eq("My Checking")
  end
end
