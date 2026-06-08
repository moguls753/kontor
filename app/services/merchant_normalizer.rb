class MerchantNormalizer
  ACQUIRER_PREFIXES = /\A(paypal|visa|mastercard|sumup|sq|izettle|klarna|paypover|amaz(on)?\s*mktp)[\s*.:-]+/i

  def self.call(raw)
    s = raw.to_s.unicode_normalize(:nfkc).strip
    return nil if s.blank?
    s = s.downcase
    s = s.sub(ACQUIRER_PREFIXES, "")          # strip processor prefix
    s = s.gsub(/\b[a-z]{2}\d{2}[a-z0-9]{10,30}\b/, " ")  # IBANs (ISO-13616 shape)
    s = s.gsub(/\b\d[\d\s\/-]{4,}\d\b/, " ")  # ref/invoice numbers, card masks, dates
    s = s.gsub(/[^a-z0-9äöüß&. ]/, " ")        # keep letters/digits/german
    s = s.gsub(/\s+/, " ").strip
    s.presence
  end
end
