# Resolves the set of in-scope account ids for the current user and applies the
# §4a internal-transfer exclusion rule. `?scope=privat` narrows to the user's
# personal (non-shared) accounts; the default (familie) is ALL of their accounts.
module ScopedAccounts
  extend ActiveSupport::Concern

  # The set `S` of in-scope account ids. Default = all accounts.
  def scoped_account_ids
    accts = Current.user.accounts
    (params[:scope] == "privat" ? accts.personal : accts).pluck(:id)
  end

  # §4a — the one rule. Restrict `scope` to in-scope accounts and exclude
  # matched internal transfers whose counterpart account is ALSO in scope
  # (both legs visible ⇒ net zero ⇒ exclude). A counterpart outside S — or an
  # orphaned leg whose counterpart account was deleted (counterpart_id NULL but
  # transfer_group_id still set) — is a real flow and stays. We key the exclusion
  # on transfer_counterpart_account_id, NOT transfer_group_id: a leg is excluded
  # only when it actually points at an in-scope counterpart. (Keying on
  # transfer_group_id would let `NULL NOT IN (...)` → NULL → falsy silently drop
  # an orphaned leg.) Empty-S guard (S2a): `NOT IN ()` is invalid SQL.
  def in_scope(scope, ids = scoped_account_ids)
    return scope.none if ids.empty?

    scope.where(account_id: ids)
         .where("transfer_counterpart_account_id IS NULL OR transfer_counterpart_account_id NOT IN (?)", ids)
  end

  # Investment/savings accounts (role-based). Excluded from the "liquid" lens — the
  # spendable runway — by both the statistics forecast and the net-worth chart.
  def investment_account_ids
    Current.user.accounts.where(role: %w[investment sparkonto]).pluck(:id)
  end

  # Parse an ISO date param, falling back to `default` on blank/invalid input. Shared by the
  # statistics + net-worth controllers, which both read `?from`/`?to` date windows.
  def parse_date(value, default)
    value.present? ? Date.iso8601(value.to_s) : default
  rescue ArgumentError, TypeError
    default
  end
end
