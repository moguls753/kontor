require "rails_helper"

RSpec.describe ProcessAccountDataJob, type: :job do
  let(:user) { create(:user) }
  let(:bc) { create(:bank_connection, user: user) }
  let(:giro) { create(:account, bank_connection: bc, iban: "DE89370400440532013000") }
  let(:spar) { create(:account, bank_connection: bc, iban: "DE12345678901234567890") }

  it "runs the matcher so counter-legs are paired (the pipeline ran)" do
    out = create(:transaction_record, account: giro, amount: -70, booking_date: Date.current,
                                      creditor_iban: spar.iban)
    inn = create(:transaction_record, :credit, account: spar, amount: 70, booking_date: Date.current,
                                               debtor_iban: giro.iban)

    described_class.perform_now(user.id)

    expect(out.reload.transfer_group_id).to be_present
    expect(inn.reload.transfer_group_id).to eq(out.transfer_group_id)
    expect(out.transfer_counterpart_account_id).to eq(spar.id)
  end

  it "is a no-op for an unknown user" do
    expect { described_class.perform_now(-1) }.not_to raise_error
  end

  it "still matches transfers + detects when the LLM step raises (fault isolation)" do
    # No llm_credential → LlmCategorizer#categorize_uncategorized raises; the matcher
    # and detector must still run.
    out = create(:transaction_record, account: giro, amount: -70, booking_date: Date.current,
                                      creditor_iban: spar.iban)
    create(:transaction_record, :credit, account: spar, amount: 70, booking_date: Date.current,
                                         debtor_iban: giro.iban)

    expect(user.llm_credential).to be_nil
    expect { described_class.perform_now(user.id) }.not_to raise_error
    expect(out.reload.transfer_group_id).to be_present
  end
end
