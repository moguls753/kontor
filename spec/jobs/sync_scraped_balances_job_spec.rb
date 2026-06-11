require "rails_helper"

RSpec.describe SyncScrapedBalancesJob, type: :job do
  let(:user) { create(:user) }

  it "enqueues a sync for an active easybank connection (password-only — runs unattended)" do
    eb = create(:bank_connection, :easybank, user: user, last_synced_at: nil)
    expect { described_class.perform_now }.to have_enqueued_job(SyncAccountsJob).with(eb.id)
  end

  it "excludes Trade Republic (manual-only — its scraped session needs a fresh 2FA code every sync)" do
    create(:bank_connection, :trade_republic, user: user, last_synced_at: nil)
    expect { described_class.perform_now }.not_to have_enqueued_job(SyncAccountsJob)
  end

  it "ignores open-banking (non-scraped) connections" do
    create(:bank_connection, user: user, provider: "enable_banking")
    expect { described_class.perform_now }.not_to have_enqueued_job(SyncAccountsJob)
  end

  it "excludes PayPal (manual-sync-only; the device push can't be approved unattended)" do
    create(:bank_connection, :paypal, user: user, last_synced_at: nil)
    expect { described_class.perform_now }.not_to have_enqueued_job(SyncAccountsJob)
  end

  it "skips connections synced within the recency window (avoids duplicate logins)" do
    create(:bank_connection, :easybank, user: user, last_synced_at: 2.hours.ago)
    expect { described_class.perform_now }.not_to have_enqueued_job(SyncAccountsJob)
  end
end
