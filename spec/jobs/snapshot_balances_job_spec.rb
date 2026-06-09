require "rails_helper"

RSpec.describe SnapshotBalancesJob, type: :job do
  it "captures a snapshot for every account with a balance" do
    create(:account, balance_amount: 100)
    create(:account, balance_amount: 200)

    expect { described_class.perform_now }.to change(BalanceSnapshot, :count).by(2)
  end

  it "does not duplicate rows on a second run the same day" do
    create(:account, balance_amount: 100)
    described_class.perform_now

    expect { described_class.perform_now }.not_to change(BalanceSnapshot, :count)
  end
end
