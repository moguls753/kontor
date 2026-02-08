class LlmCategorizer
  BATCH_SIZE = 30
  MAX_TRANSACTIONS = 500

  def initialize(user)
    @user = user
    @credential = user.llm_credential
    @categories = user.categories.pluck(:id, :name).to_h
  end

  def categorize_uncategorized
    raise "LLM not configured" unless @credential

    transactions = @user.transaction_records.uncategorized.order(booking_date: :desc).limit(MAX_TRANSACTIONS)
    results = { total: transactions.size, categorized: 0, failed: 0, breakdown: Hash.new(0) }

    return results if transactions.empty?

    category_names = @categories.values

    transactions.each_slice(BATCH_SIZE) do |batch|
      response = call_llm(batch, category_names)
      assignments = parse_response(response)
      applied, batch_breakdown = apply_assignments(batch, assignments)
      results[:categorized] += applied
      batch_breakdown.each { |name, count| results[:breakdown][name] += count }
    rescue => e
      results[:failed] += batch.size
      Rails.logger.error("LLM categorization error: #{e.message}")
    end

    results
  end

  private

  def call_llm(batch, category_names)
    uri = URI("#{@credential.base_url.chomp('/')}/chat/completions")
    headers = { "Content-Type" => "application/json" }
    headers["Authorization"] = "Bearer #{@credential.api_key}" if @credential.api_key.present?

    body = {
      model: @credential.llm_model,
      messages: [
        { role: "system", content: system_prompt },
        { role: "user", content: user_prompt(batch, category_names) }
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
    data.dig("choices", 0, "message", "content") || raise("No content in LLM response")
  end

  def system_prompt
    <<~PROMPT.strip
      <role>
      You are a bank transaction categorizer. Your task is to assign each transaction to the most fitting category from the provided list.
      </role>

      <rules>
      - ONLY use category names exactly as they appear in the <categories> list
      - NEVER invent, modify, or create new category names
      - If a transaction does not clearly match any category, use null
      - When in doubt, prefer null over guessing
      - Base your decision on the remittance text, creditor name, and debtor name
      - Respond with ONLY a JSON object mapping transaction IDs to category names or null
      </rules>

      <response_format>
      {"1": "Category Name", "2": "Another Category", "3": null}
      </response_format>
    PROMPT
  end

  def user_prompt(batch, category_names)
    lines = batch.map do |t|
      parts = [ "id:#{t.id}" ]
      parts << t.remittance if t.remittance.present?
      parts << "creditor: #{t.creditor_name}" if t.creditor_name.present?
      parts << "debtor: #{t.debtor_name}" if t.debtor_name.present?
      "- #{parts.join(' | ')}"
    end

    <<~PROMPT.strip
      <categories>
      #{category_names.join(', ')}
      </categories>

      <transactions>
      #{lines.join("\n")}
      </transactions>
    PROMPT
  end

  def parse_response(content)
    json_str = content.strip
    json_str = json_str.match(/```(?:json)?\s*(.*?)\s*```/m)&.[](1) || json_str
    JSON.parse(json_str)
  rescue JSON::ParserError => e
    Rails.logger.error("LLM response parse error: #{e.message}")
    {}
  end

  def apply_assignments(batch, assignments)
    name_to_id = @categories.each_with_object({}) { |(id, name), h| h[name.downcase] = id }
    applied = 0
    breakdown = Hash.new(0)

    batch.each do |transaction|
      category_name = assignments[transaction.id.to_s]
      next unless category_name.is_a?(String)

      category_id = name_to_id[category_name.downcase]
      next unless category_id

      transaction.update_column(:category_id, category_id)
      applied += 1
      breakdown[@categories[category_id]] += 1
    end

    [ applied, breakdown ]
  end
end
