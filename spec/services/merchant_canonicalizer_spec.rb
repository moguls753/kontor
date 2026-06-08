require "rails_helper"

RSpec.describe MerchantCanonicalizer do
  let(:user) { create(:user) }
  subject { described_class.new(user) }

  # mirrors LlmCategorizer spec stub: the canonicalizer returns a JSON array
  # [{raw, canonical, type}] in choices[0].message.content
  def stub_llm(rows)
    body = { choices: [ { message: { content: rows.to_json } } ] }
    response = instance_double(Net::HTTPResponse, code: "200", body: body.to_json)
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:post).and_return(response)
    http
  end

  it "offers groceries and transport among the allowed types in the prompt" do
    prompt = subject.send(:system_prompt)

    expect(prompt).to include("groceries")
    expect(prompt).to include("transport")
    # the originally-cataloged types must still be present
    expect(prompt).to include("subscription", "shopping", "transfer", "other")
  end

  context "with an LLM credential" do
    let!(:credential) { create(:llm_credential, user: user) }

    it "writes merchant_aliases on a cache miss" do
      stub_llm([ { raw: "spotify", canonical: "Spotify", type: "subscription" } ])

      res = subject.resolve([ "spotify" ])

      expect(res[:canonicals]["spotify"]).to eq(canonical: "Spotify", type: "subscription")
      alias_row = MerchantAlias.find_by(raw_key: "spotify")
      expect(alias_row.canonical_name).to eq("Spotify")
      expect(alias_row.source).to eq("llm")
    end

    it "skips the LLM on a cache hit" do
      create(:merchant_alias, user: user, raw_key: "spotify", canonical_name: "Spotify", source: "llm")
      expect(Net::HTTP).not_to receive(:new)

      res = subject.resolve([ "spotify" ])
      expect(res[:canonicals]["spotify"][:canonical]).to eq("Spotify")
    end

    it "sends ONLY the provided name strings to the LLM (whitelist, not blacklist)" do
      http = stub_llm([])
      keys = [ "spotify", "netflix" ]

      expect(http).to receive(:post) do |_uri, body, _headers|
        content = JSON.parse(body)["messages"].last["content"]
        expect(content).to include("spotify", "netflix")

        # Strip the provided keys (each rendered as a "- key" line) out of the body.
        # Whatever remains MUST be the static template — i.e. the LLM never sees
        # anything beyond the bare name strings (no amounts/dates/IBANs/account data).
        remainder = content
        keys.each { |k| remainder = remainder.sub("- #{k}\n", "").sub("- #{k}", "") }
        template = subject.send(:user_prompt, []).sub("\n\n", "\n")
        expect(remainder).to eq(template)

        instance_double(Net::HTTPResponse, code: "200",
          body: { choices: [ { message: { content: "[]" } } ] }.to_json)
      end

      subject.resolve(keys)
    end

    it "upgrades a deterministic alias and returns it in :upgrades" do
      create(:merchant_alias, user: user, raw_key: "spotify", canonical_name: "Spotify", source: "deterministic", merchant_type: nil)
      stub_llm([ { raw: "spotify", canonical: "Spotify AB", type: "subscription" } ])

      res = subject.resolve([ "spotify" ])

      expect(MerchantAlias.find_by(raw_key: "spotify").canonical_name).to eq("Spotify AB")
      expect(res[:upgrades]).to include(
        a_hash_including(raw_key: "spotify", old_canonical: "Spotify", new_canonical: "Spotify AB")
      )
    end

    it "never overwrites an existing llm canonical" do
      create(:merchant_alias, user: user, raw_key: "spotify", canonical_name: "Spotify", source: "llm")
      # even if the LLM were called, the cache-hit short-circuits; assert no upgrade
      res = subject.resolve([ "spotify" ])
      expect(res[:upgrades]).to be_empty
      expect(MerchantAlias.find_by(raw_key: "spotify").canonical_name).to eq("Spotify")
    end
  end

  context "without an LLM credential" do
    it "degrades to a titleized deterministic alias" do
      res = subject.resolve([ "acme corp" ])

      expect(res[:canonicals]["acme corp"][:canonical]).to eq("Acme Corp")
      alias_row = MerchantAlias.find_by(raw_key: "acme corp")
      expect(alias_row.source).to eq("deterministic")
      expect(res[:upgrades]).to be_empty
    end

    it "does not call the LLM" do
      expect(Net::HTTP).not_to receive(:new)
      subject.resolve([ "acme corp" ])
    end
  end
end
