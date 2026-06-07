require "rails_helper"
require "webmock/rspec"

RSpec.describe Paypal::ScraperClient do
  let(:base) { "http://paypal-scraper:8000" }
  let(:client) { described_class.new(base_url: base, token: "secret-token") }

  it "POSTs /sync with the sidecar token and parses JSON (string keys)" do
    stub = stub_request(:post, "#{base}/sync")
      .with(headers: { "X-Sidecar-Token" => "secret-token" })
      .to_return(status: 200, body: {
        status: "ok",
        date_from: "2026-05-07", date_to: "2026-06-06",
        transactions: [{ id: "55X63072JY995300U", amount: "-8.15" }]
      }.to_json)

    result = client.sync(username: "u", password: "p")

    expect(stub).to have_been_requested
    expect(result["transactions"].first["id"]).to eq("55X63072JY995300U")
  end

  it "omits date params when not given and includes them when given" do
    with_dates = stub_request(:post, "#{base}/sync")
      .with(body: hash_including("date_from" => "2026-05-01", "date_to" => "2026-06-01"))
      .to_return(status: 200, body: { status: "ok", transactions: [] }.to_json)

    client.sync(username: "u", password: "p", date_from: "2026-05-01", date_to: "2026-06-01")
    expect(with_dates).to have_been_requested
  end

  # --- NON-RETRYABLE outcomes (must never be registered in any retry_on) ---
  it "raises CaptchaBlocked on 422 captcha_blocked" do
    stub_request(:post, "#{base}/sync")
      .to_return(status: 422, body: { error: "captcha_blocked", message: "security check" }.to_json)

    expect { client.sync(username: "u", password: "p") }
      .to raise_error(Paypal::CaptchaBlocked)
  end

  it "raises PushTimeout on 409 push_timeout" do
    stub_request(:post, "#{base}/sync")
      .to_return(status: 409, body: { error: "push_timeout", message: "not approved" }.to_json)

    expect { client.sync(username: "u", password: "p") }
      .to raise_error(Paypal::PushTimeout)
  end

  it "CaptchaBlocked and PushTimeout are NOT subclasses of the retryable transient errors" do
    expect(Paypal::CaptchaBlocked.ancestors).not_to include(Paypal::ApiError)
    expect(Paypal::CaptchaBlocked.ancestors).not_to include(Paypal::SidecarUnavailableError)
    expect(Paypal::PushTimeout.ancestors).not_to include(Paypal::ApiError)
    expect(Paypal::PushTimeout.ancestors).not_to include(Paypal::SidecarUnavailableError)
  end

  it "raises LoginFailed on 422 login_failed" do
    stub_request(:post, "#{base}/sync")
      .to_return(status: 422, body: { error: "login_failed", message: "bad creds" }.to_json)

    expect { client.sync(username: "u", password: "p") }
      .to raise_error(Paypal::LoginFailed)
  end

  it "raises a distinct InvalidRequestError on 422 invalid_request (NOT scraper_unavailable)" do
    stub_request(:post, "#{base}/sync")
      .to_return(status: 422, body: { error: "invalid_request", message: "bad body" }.to_json)

    expect { client.sync(username: "u", password: "p") }
      .to raise_error(Paypal::InvalidRequestError)
    # It must NOT be a transient/unavailable error (those are retryable).
    expect(Paypal::InvalidRequestError.ancestors).not_to include(Paypal::SidecarUnavailableError)
    expect(Paypal::InvalidRequestError.ancestors).not_to include(Paypal::ApiError)
  end

  it "raises ApiError on any other unmapped 422" do
    stub_request(:post, "#{base}/sync")
      .to_return(status: 422, body: { error: "weird_unmapped", message: "?" }.to_json)

    expect { client.sync(username: "u", password: "p") }
      .to raise_error(Paypal::ApiError)
  end

  it "raises SidecarUnavailableError on 503" do
    stub_request(:post, "#{base}/sync")
      .to_return(status: 503, body: { error: "transient", message: "down" }.to_json)

    expect { client.sync(username: "u", password: "p") }
      .to raise_error(Paypal::SidecarUnavailableError)
  end

  it "raises SidecarUnavailableError when the connection is refused" do
    stub_request(:post, "#{base}/sync").to_raise(Errno::ECONNREFUSED)

    expect { client.sync(username: "u", password: "p") }
      .to raise_error(Paypal::SidecarUnavailableError)
  end
end
