require "rails_helper"

RSpec.describe MerchantNormalizer do
  def norm(raw) = described_class.call(raw)

  it "strips acquirer/processor prefixes" do
    expect(norm("PAYPAL *SPOTIFY")).to eq("spotify")
    expect(norm("VISA NETFLIX")).to eq("netflix")
    expect(norm("SumUp .Bakery")).to eq("bakery")
  end

  it "strips reference / invoice numbers" do
    expect(norm("REWE 12345678")).to eq("rewe")
    expect(norm("Rent 2026 01 15")).to eq("rent")
  end

  it "strips IBAN-like tokens" do
    expect(norm("Rent DE89370400440532013000")).to eq("rent")
  end

  it "strips shorter (18-19 digit) IBANs (AT/NL/CH/GB)" do
    expect(norm("Rent CH9300762011623852957")).to eq("rent")
    expect(norm("Rent AT611904300234573201")).to eq("rent")
    expect(norm("Rent NL91ABNA0417164300")).to eq("rent")
    expect(norm("Rent GB29NWBK60161331926819")).to eq("rent")
  end

  it "does not eat ordinary merchant words" do
    expect(norm("Müller Drogerie")).to eq("müller drogerie")
    expect(norm("Acme Corp")).to eq("acme corp")
    expect(norm("Spotify")).to eq("spotify")
  end

  it "collapses whitespace and lowercases" do
    expect(norm("   Acme   Corp   ")).to eq("acme corp")
  end

  it "returns nil for blank input" do
    expect(norm("")).to be_nil
    expect(norm(nil)).to be_nil
    expect(norm("   ")).to be_nil
  end

  it "keeps german characters" do
    expect(norm("Müller Drogerie")).to eq("müller drogerie")
  end

  it "normalizes unicode (NFKC) including the U+2212 minus" do
    # full-width / unicode forms collapse to ascii where applicable
    expect(norm("ＳＰＯＴＩＦＹ")).to eq("spotify")
    # U+2212 (minus sign) is not in the kept set → dropped to space → stripped
    expect(norm("Spotify − Premium")).to eq("spotify premium")
  end
end
