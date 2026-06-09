# Suggests a normalized `role` (and a `shared` hint) for an account from its
# provider + raw account_type + name. Heuristic only — a DEFAULT the user can
# always override. It NEVER touches a `role_locked` account (the user has set the
# role/shared by hand; inference must not stomp it).
#
# `account_type` stays the raw provider value; `role` is our normalized concept:
#   giro | sparkonto | investment | kreditkarte | zahlung | sonstiges
#
# Usage:
#   AccountRoleInferrer.new(account).infer!   # persists role (+ shared if hinted)
class AccountRoleInferrer
  def initialize(account)
    @account = account
  end

  # Infers and persists the role. Returns the account. A no-op (returns early)
  # when the user has locked the role.
  def infer!
    return @account if @account.role_locked?

    attrs = { role: inferred_role }
    # Only ever PROPOSE shared=true; never flip a user's account back to false.
    attrs[:shared] = true if shared_hint? && !@account.shared?
    @account.update!(attrs)
    @account
  end

  # The role this heuristic would pick (pure; no persistence).
  def inferred_role
    return "kreditkarte" if kreditkarte?
    return "investment" if provider == "trade_republic"
    return "zahlung" if provider == "paypal"

    case raw_type
    when /saving|tagesgeld/ then "sparkonto"
    when /depot|securit|invest/ then "investment"
    when /card|credit/ then "kreditkarte"
    else "giro" # Giro / Tomorrow / unknown
    end
  end

  def shared_hint?
    haystack.match?(/gemeinschaft|joint/)
  end

  private

  def kreditkarte?
    return true if provider == "easybank" # easybank connection = credit card
    haystack.match?(/kreditkarte|credit/)
  end

  def provider
    @account.bank_connection&.provider
  end

  def raw_type
    @account.account_type.to_s.downcase
  end

  # Name + raw account_type, lowercased, for keyword sniffing.
  def haystack
    [ @account.name, @account.account_type ].compact.join(" ").downcase
  end
end
