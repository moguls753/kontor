require "rails_helper"

RSpec.describe "Api::V1::Categories", type: :request do
  let(:user) { create(:user, password: "password123") }
  before { post session_path, params: { email_address: user.email_address, password: "password123" }, as: :json }

  it "lists categories" do
    create(:category, user: user, name: "Groceries")
    get api_v1_categories_path, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.first["name"]).to eq("Groceries")
  end

  it "creates a category" do
    post api_v1_categories_path, params: { category: { name: "Transport" } }, as: :json
    expect(response).to have_http_status(:created)
    expect(user.categories.count).to eq(1)
  end

  it "rejects duplicate name" do
    create(:category, user: user, name: "Transport")
    post api_v1_categories_path, params: { category: { name: "Transport" } }, as: :json
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "updates a category" do
    category = create(:category, user: user, name: "Old Name")
    patch api_v1_category_path(category), params: { category: { name: "New Name" } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(category.reload.name).to eq("New Name")
  end

  it "destroys a category" do
    category = create(:category, user: user)
    delete api_v1_category_path(category), as: :json
    expect(response).to have_http_status(:no_content)
    expect(Category.find_by(id: category.id)).to be_nil
  end

  it "creates default categories" do
    post create_defaults_api_v1_categories_path, params: { locale: "en" }, as: :json
    expect(response).to have_http_status(:ok)
    expect(user.categories.count).to eq(17)
  end

  it "scopes to current user" do
    other_user = create(:user)
    other_category = create(:category, user: other_user, name: "Other")
    get api_v1_categories_path, as: :json
    expect(response.parsed_body).to be_empty
  end

  describe "POST /api/v1/categories/suggest" do
    it "returns suggestions when LLM is configured" do
      create(:llm_credential, user: user)
      bank_connection = create(:bank_connection, user: user)
      account = create(:account, bank_connection: bank_connection)
      create(:transaction_record, account: account, remittance: "Netflix")

      suggestions = [ "Streaming", "Transport" ]
      body = { choices: [ { message: { content: suggestions.to_json } } ] }
      response_double = instance_double(Net::HTTPResponse, code: "200", body: body.to_json)
      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:post).and_return(response_double)

      post suggest_api_v1_categories_path, params: { locale: "en" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["suggestions"]).to include("Streaming", "Transport")
    end

    it "returns 422 when LLM is not configured" do
      post suggest_api_v1_categories_path, params: { locale: "en" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to eq("LLM not configured")
    end
  end
end
