require "rails_helper"

RSpec.describe CategorySuggester do
  let(:user) { create(:user) }
  let!(:credential) { create(:llm_credential, user: user) }
  let(:bank_connection) { create(:bank_connection, user: user) }
  let(:account) { create(:account, bank_connection: bank_connection) }
  let!(:groceries) { create(:category, user: user, name: "Groceries") }

  let!(:tx1) { create(:transaction_record, account: account, remittance: "Netflix Monthly", creditor_name: "Netflix Inc", amount: -12.99, creditor_iban: "DE89370400440532013000", bank_transaction_code: "DIRECT_DEBIT") }
  let!(:tx2) { create(:transaction_record, account: account, remittance: "DB Vertrieb", creditor_name: "Deutsche Bahn", amount: -45.00, bank_transaction_code: "CARD_PAYMENT") }
  let!(:tx3) { create(:transaction_record, account: account, remittance: "REWE Markt", creditor_name: "REWE", amount: -28.50) }

  subject { described_class.new(user) }

  def stub_llm(suggestions)
    body = { choices: [ { message: { content: suggestions.to_json } } ] }
    response = instance_double(Net::HTTPResponse, code: "200", body: body.to_json)
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:post).and_return(response)
    http
  end

  it "suggests new categories from uncategorized transactions" do
    stub_llm([ "Streaming", "Transport", "Groceries" ])

    result = subject.suggest

    expect(result[:suggestions]).to include("Streaming", "Transport")
  end

  it "does not suggest names that already exist as categories" do
    stub_llm([ "Streaming", "Groceries", "Transport" ])

    result = subject.suggest

    expect(result[:suggestions]).not_to include("Groceries")
  end

  it "deduplicates case-insensitively against existing categories" do
    stub_llm([ "groceries", "Streaming" ])

    result = subject.suggest

    expect(result[:suggestions]).not_to include("groceries")
    expect(result[:suggestions]).to include("Streaming")
  end

  it "does not send amounts or IBANs in the prompt" do
    http = stub_llm([])

    expect(http).to receive(:post) do |_uri, body, _headers|
      content = JSON.parse(body)["messages"].last["content"]
      expect(content).not_to include("12.99", "45.00", "28.50", "DE89")
      expect(content).to include("Netflix Monthly", "DB Vertrieb")
      instance_double(Net::HTTPResponse, code: "200", body: { choices: [ { message: { content: "[]" } } ] }.to_json)
    end

    subject.suggest
  end

  it "sends bank_transaction_code in the prompt" do
    http = stub_llm([])

    expect(http).to receive(:post) do |_uri, body, _headers|
      content = JSON.parse(body)["messages"].last["content"]
      expect(content).to include("DIRECT_DEBIT", "CARD_PAYMENT")
      instance_double(Net::HTTPResponse, code: "200", body: { choices: [ { message: { content: "[]" } } ] }.to_json)
    end

    subject.suggest
  end

  it "handles API errors gracefully" do
    response = instance_double(Net::HTTPResponse, code: "500", body: "error")
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:post).and_return(response)

    result = subject.suggest

    expect(result[:suggestions]).to eq([])
  end

  it "raises when LLM is not configured" do
    credential.destroy
    user.reload

    expect { described_class.new(user).suggest }.to raise_error("LLM not configured")
  end

  it "returns empty suggestions when no uncategorized transactions exist" do
    TransactionRecord.update_all(category_id: groceries.id)
    stub_llm([])

    result = subject.suggest

    expect(result[:suggestions]).to eq([])
  end

  it "limits suggestions to 10" do
    stub_llm(("A".."Z").to_a)

    result = subject.suggest

    expect(result[:suggestions].size).to be <= 10
  end
end
