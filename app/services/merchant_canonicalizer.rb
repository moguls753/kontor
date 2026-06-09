class MerchantCanonicalizer
  BATCH_SIZE = 40

  def initialize(user)
    @user = user
    @credential = user.llm_credential
  end

  # norm_keys: Array<String>
  # → { canonicals: { norm_key => { canonical:, type: } },
  #     upgrades:   [ { raw_key:, old_canonical:, new_canonical: } ] }   # deterministic→LLM upgrades
  def resolve(norm_keys)
    keys   = norm_keys.compact.uniq
    cached = MerchantAlias.where(user: @user, raw_key: keys).index_by(&:raw_key)

    # S1: a cached row written WITHOUT an LLM ("deterministic") is a weak placeholder. If THIS
    # user has an LLM, re-resolve those too so a better mapping upgrades it in place (one-time).
    upgradable = @credential ? cached.values.select { |a| a.source == "deterministic" }.map(&:raw_key) : []
    to_llm     = (keys - cached.keys) + upgradable

    canonicals = {}
    upgrades   = []
    cached.each { |k, a| canonicals[k] = { canonical: a.canonical_name, type: a.merchant_type } }
    return { canonicals:, upgrades: } if to_llm.empty?

    if @credential
      to_llm.uniq.each_slice(BATCH_SIZE) do |batch|
        llm_map = (call_llm(batch) rescue {})           # graceful per-batch
        batch.each do |k|
          got   = llm_map[k]
          entry = got || { canonical: k.titleize, type: nil }
          row   = MerchantAlias.find_or_initialize_by(user: @user, raw_key: k)
          # S2: NEVER overwrite an existing LLM/manual canonical (it pins series identity via the
          # fingerprint's canonical_name). Only write when new, or when upgrading a deterministic row.
          if row.new_record? || (row.source == "deterministic" && got)
            old_canonical = row.canonical_name                      # nil for new rows
            row.canonical_name = entry[:canonical].presence || k.titleize
            row.merchant_type  = entry[:type]
            row.source = got ? "llm" : "deterministic"
            row.save!
            # B3′: record real upgrades so the DETECTOR can re-point/merge affected series (§5.6 Pre-step 0)
            if old_canonical.present? && old_canonical != row.canonical_name
              upgrades << { raw_key: k, old_canonical:, new_canonical: row.canonical_name }
            end
          end
          canonicals[k] = { canonical: row.canonical_name, type: row.merchant_type }
        end
      end
    else
      # No LLM: degrade to deterministic. Persist as source:"deterministic" so a future
      # LLM-enabled run can upgrade it (S1) — see §5.6 Pre-step 0 for the resulting re-point/merge.
      to_llm.each do |k|
        row = MerchantAlias.find_or_create_by!(user: @user, raw_key: k) do |a|
          a.canonical_name = k.titleize
          a.source = "deterministic"
        end
        canonicals[k] = { canonical: row.canonical_name, type: row.merchant_type }
      end
    end
    { canonicals:, upgrades: }
  end

  private

  # Mirrors LlmCategorizer#call_llm EXACTLY. Sends ONLY the strings in `batch`.
  # → { norm_key => { canonical:, type: } } for keys the LLM mapped.
  def call_llm(batch)
    uri = URI("#{@credential.base_url.chomp('/')}/chat/completions")
    headers = { "Content-Type" => "application/json" }
    headers["Authorization"] = "Bearer #{@credential.api_key}" if @credential.api_key.present?

    body = {
      model: @credential.llm_model,
      messages: [
        { role: "system", content: system_prompt },
        { role: "user", content: user_prompt(batch) }
      ],
      temperature: 0
    }

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 30
    http.read_timeout = 60

    response = http.post(uri.request_uri, body.to_json, headers)

    unless response.code.to_i.between?(200, 299)
      raise "LLM API error: HTTP #{response.code}"
    end

    data = JSON.parse(response.body)
    content = data.dig("choices", 0, "message", "content") || raise("No content in LLM response")
    parse_response(content)
  end

  def system_prompt
    <<~PROMPT.strip
      <role>
      You map raw bank counterparty strings to their canonical merchant brand and type.
      </role>

      <rules>
      - For each raw string, return its canonical merchant brand (e.g. "PAYPAL *SPOTIFY" → "Spotify")
      - Pick type from: subscription, utility, rent, salary, insurance, loan, groceries, transport, shopping, transfer, investment, other
      - Classify by what the MERCHANT is, not by category: a supermarket like "Penny" or "Aldi" is groceries; a transport provider like "Deutsche Bahn" or a transit ticket is transport; a streaming/membership service is subscription; an investment broker like "Scalable Capital" or "Trade Republic" is investment
      - If you cannot confidently identify a brand, use a clean Title-Cased version of the raw string
      - Use null for type when unsure
      - Respond with ONLY a JSON array, no prose
      </rules>

      <response_format>
      [{"raw": "<input string>", "canonical": "Brand", "type": "subscription"}]
      </response_format>
    PROMPT
  end

  def user_prompt(batch)
    lines = batch.map { |k| "- #{k}" }
    <<~PROMPT.strip
      <strings>
      #{lines.join("\n")}
      </strings>
    PROMPT
  end

  # → { raw_key => { canonical:, type: } }
  def parse_response(content)
    json_str = content.strip
    json_str = json_str.match(/```(?:json)?\s*(.*?)\s*```/m)&.[](1) || json_str
    parsed = JSON.parse(json_str)
    arr = parsed.is_a?(Array) ? parsed : parsed.values
    arr.each_with_object({}) do |item, h|
      next unless item.is_a?(Hash)
      raw = item["raw"].to_s
      next if raw.blank?
      canonical = item["canonical"].to_s
      next if canonical.blank?
      h[raw] = { canonical:, type: item["type"].presence }
    end
  rescue JSON::ParserError => e
    Rails.logger.error("Merchant canonicalizer parse error: #{e.message}")
    {}
  end
end
