require "rails_helper"

RSpec.describe AccountRoleInferrer do
  def account_for(connection_trait, **attrs)
    bc = build(:bank_connection, *Array(connection_trait))
    build(:account, bank_connection: bc, **attrs)
  end

  describe "#inferred_role" do
    it "maps Trade Republic to investment" do
      expect(AccountRoleInferrer.new(account_for(:trade_republic)).inferred_role).to eq("investment")
    end

    it "maps easybank credit card to kreditkarte" do
      expect(AccountRoleInferrer.new(account_for(:easybank, name: "easybank Kreditkarte")).inferred_role).to eq("kreditkarte")
    end

    it "maps PayPal to zahlung" do
      expect(AccountRoleInferrer.new(account_for(:paypal)).inferred_role).to eq("zahlung")
    end

    it "maps Tomorrow (gocardless giro) to giro" do
      expect(AccountRoleInferrer.new(account_for(:gocardless, name: "Tomorrow")).inferred_role).to eq("giro")
    end

    it "maps a savings raw account_type to sparkonto" do
      expect(AccountRoleInferrer.new(account_for([], account_type: "savings")).inferred_role).to eq("sparkonto")
    end
  end

  describe "#shared_hint?" do
    it "suggests shared when the name contains Gemeinschaft" do
      expect(AccountRoleInferrer.new(account_for([], name: "Gemeinschaftskonto")).shared_hint?).to be(true)
    end

    it "does not suggest shared for a normal name" do
      expect(AccountRoleInferrer.new(account_for([], name: "Girokonto")).shared_hint?).to be(false)
    end
  end

  describe "#infer!" do
    it "persists the inferred role" do
      bc = create(:bank_connection, :trade_republic)
      account = create(:account, bank_connection: bc, role: nil, role_locked: false)
      account.update_column(:role, nil)

      AccountRoleInferrer.new(account).infer!
      expect(account.reload.role).to eq("investment")
    end

    it "sets shared from the hint without forcing it false" do
      bc = create(:bank_connection)
      account = create(:account, bank_connection: bc, name: "Gemeinschaftskonto", role_locked: false)

      AccountRoleInferrer.new(account).infer!
      expect(account.reload.shared).to be(true)
    end

    it "never overrides a role_locked account" do
      bc = create(:bank_connection, :trade_republic)
      account = create(:account, bank_connection: bc, role: "giro", role_locked: true)

      AccountRoleInferrer.new(account).infer!
      expect(account.reload.role).to eq("giro")
    end
  end
end
