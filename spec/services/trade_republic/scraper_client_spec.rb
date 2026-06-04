require "rails_helper"
require "webmock/rspec"

RSpec.describe TradeRepublic::ScraperClient do
  let(:base) { "http://tr-scraper:8000" }
  let(:client) { described_class.new(base_url: base, token: "secret-token") }

  it "POSTs the balance request with the sidecar token and parses JSON" do
    stub = stub_request(:post, "#{base}/balance")
      .with(headers: { "X-Sidecar-Token" => "secret-token" })
      .to_return(status: 200, body: { total: "12487.65", currency: "EUR", session_blob: "refreshed", warnings: [] }.to_json)

    result = client.balance(phone_number: "+4915112345678", session_blob: "blob")

    expect(stub).to have_been_requested
    expect(result[:total]).to eq("12487.65")
    expect(result[:session_blob]).to eq("refreshed")
  end

  it "returns the pairing id from pair_start" do
    stub_request(:post, "#{base}/pairing/start")
      .to_return(status: 200, body: { pairing_id: "pid", countdown_seconds: 60, channel: "push" }.to_json)

    expect(client.pair_start(phone_number: "+4915112345678", pin: "1234")[:pairing_id]).to eq("pid")
  end

  it "raises SessionExpiredError on 409" do
    stub_request(:post, "#{base}/balance")
      .to_return(status: 409, body: { error: "SESSION_EXPIRED", message: "expired" }.to_json)

    expect { client.balance(phone_number: "x", session_blob: "y") }
      .to raise_error(TradeRepublic::SessionExpiredError)
  end

  it "raises ApiError on a 5xx (transient)" do
    stub_request(:post, "#{base}/balance")
      .to_return(status: 503, body: { error: "TRANSIENT", message: "upstream down" }.to_json)

    expect { client.balance(phone_number: "x", session_blob: "y") }
      .to raise_error(TradeRepublic::ApiError)
  end

  it "raises SidecarUnavailableError when the connection is refused" do
    stub_request(:post, "#{base}/balance").to_raise(Errno::ECONNREFUSED)

    expect { client.balance(phone_number: "x", session_blob: "y") }
      .to raise_error(TradeRepublic::SidecarUnavailableError)
  end

  it "raises PairingExpiredError on 410" do
    stub_request(:post, "#{base}/pairing/finish")
      .to_return(status: 410, body: { error: "PAIRING_EXPIRED", message: "gone" }.to_json)

    expect { client.pair_finish(pairing_id: "p", code: "1234") }
      .to raise_error(TradeRepublic::PairingExpiredError)
  end

  it "raises PairingFailedError on 422" do
    stub_request(:post, "#{base}/pairing/finish")
      .to_return(status: 422, body: { error: "PAIRING_FAILED", message: "wrong code" }.to_json)

    expect { client.pair_finish(pairing_id: "p", code: "0000") }
      .to raise_error(TradeRepublic::PairingFailedError)
  end
end
