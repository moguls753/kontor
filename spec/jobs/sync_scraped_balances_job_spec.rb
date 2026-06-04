require "rails_helper"

RSpec.describe SyncScrapedBalancesJob, type: :job do
  let(:user) { create(:user) }

  it "enqueues a sync for an active Trade Republic connection" do
    tr = create(:bank_connection, :trade_republic, user: user, last_synced_at: nil)
    expect { described_class.perform_now }.to have_enqueued_job(SyncAccountsJob).with(tr.id)
  end

  it "ignores non-Trade-Republic connections" do
    create(:bank_connection, user: user, provider: "enable_banking")
    expect { described_class.perform_now }.not_to have_enqueued_job(SyncAccountsJob)
  end

  it "skips connections synced within the recency window (avoids duplicate logins)" do
    create(:bank_connection, :trade_republic, user: user, last_synced_at: 2.hours.ago)
    expect { described_class.perform_now }.not_to have_enqueued_job(SyncAccountsJob)
  end
end
