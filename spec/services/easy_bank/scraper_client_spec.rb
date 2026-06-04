require "rails_helper"
require "webmock/rspec"

RSpec.describe EasyBank::ScraperClient do
  let(:base) { "http://easybank-scraper:8000" }
  let(:client) { described_class.new(base_url: base, token: "secret-token") }

  it "POSTs /sync with the sidecar token and parses JSON (string keys)" do
    stub = stub_request(:post, "#{base}/sync")
      .with(headers: { "X-Sidecar-Token" => "secret-token" })
      .to_return(status: 200, body: {
        status: "ok",
        balance: { value: "-980.31", currency: "EUR" },
        transactions: [{ id: "t1", amount: "-26.80" }],
        otp_required: false
      }.to_json)

    result = client.sync(username: "u", password: "p")

    expect(stub).to have_been_requested
    expect(result["balance"]["value"]).to eq("-980.31")
    expect(result["transactions"].first["id"]).to eq("t1")
  end

  it "returns the login payload on 200" do
    stub_request(:post, "#{base}/login")
      .to_return(status: 200, body: { status: "ok", otp_required: false }.to_json)

    expect(client.login(username: "u", password: "p")["status"]).to eq("ok")
  end

  # --- 409 is overloaded: disambiguated on the body `error`, NOT the status ---
  it "raises MtanRequired (carrying the pairing handle) on 409 mtan_required" do
    stub_request(:post, "#{base}/login")
      .to_return(status: 409, body: {
        error: "mtan_required", message: "code needed",
        pairing_id: "pid-1", masked_phone: "**********5836", reference: "6W0SH1", expires_in: 300
      }.to_json)

    expect { client.login(username: "u", password: "p") }
      .to raise_error(EasyBank::MtanRequired) do |e|
        expect(e.pairing_id).to eq("pid-1")
        expect(e.masked_phone).to eq("**********5836")
        expect(e.reference).to eq("6W0SH1")
        expect(e.expires_in).to eq(300)
      end
  end

  it "raises SessionExpiredError on 409 session_expired" do
    stub_request(:post, "#{base}/sync")
      .to_return(status: 409, body: { error: "session_expired", message: "gone" }.to_json)

    expect { client.sync(username: "u", password: "p") }
      .to raise_error(EasyBank::SessionExpiredError)
  end

  # --- 422 sub-cases, also keyed on the body `error` ---
  it "raises MtanFailed on 422 mtan_failed" do
    stub_request(:post, "#{base}/mtan")
      .to_return(status: 422, body: { error: "mtan_failed", message: "wrong code" }.to_json)

    expect { client.submit_mtan(pairing_id: "p", code: "0000") }
      .to raise_error(EasyBank::MtanFailed)
  end

  it "raises LoginFailed on 422 login_failed" do
    stub_request(:post, "#{base}/login")
      .to_return(status: 422, body: { error: "login_failed", message: "bad creds" }.to_json)

    expect { client.login(username: "u", password: "p") }
      .to raise_error(EasyBank::LoginFailed)
  end

  it "raises ApiError on 422 invalid_request" do
    stub_request(:post, "#{base}/sync")
      .to_return(status: 422, body: { error: "invalid_request", message: "bad body" }.to_json)

    expect { client.sync(username: "u", password: "p") }
      .to raise_error(EasyBank::ApiError)
  end

  it "raises SidecarUnavailableError on 503" do
    stub_request(:post, "#{base}/sync")
      .to_return(status: 503, body: { error: "transient", message: "down" }.to_json)

    expect { client.sync(username: "u", password: "p") }
      .to raise_error(EasyBank::SidecarUnavailableError)
  end

  it "raises SidecarUnavailableError when the connection is refused" do
    stub_request(:post, "#{base}/sync").to_raise(Errno::ECONNREFUSED)

    expect { client.sync(username: "u", password: "p") }
      .to raise_error(EasyBank::SidecarUnavailableError)
  end
end
