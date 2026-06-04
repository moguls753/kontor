require "rails_helper"

RSpec.describe SyncAllAccountsJob, type: :job do
  let(:user) { create(:user) }

  it "enqueues a sync for open-banking connections" do
    eb = create(:bank_connection, user: user, provider: "enable_banking")
    expect { described_class.perform_now }.to have_enqueued_job(SyncAccountsJob).with(eb.id)
  end

  it "excludes Trade Republic (scraped once a day by SyncScrapedBalancesJob)" do
    create(:bank_connection, :trade_republic, user: user)
    expect { described_class.perform_now }.not_to have_enqueued_job(SyncAccountsJob)
  end
end
