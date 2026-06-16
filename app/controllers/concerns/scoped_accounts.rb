# Resolves the set of in-scope account ids for the current user and applies the
# §4a internal-transfer exclusion rule. `?scope=privat` narrows to the user's
# personal (non-shared) accounts; the default ("gemeinsam") is the shared
# Gemeinschaftskonto(s). The two lenses PARTITION the accounts (personal vs shared),
# so the same money is never summed across both within one view.
module ScopedAccounts
  extend ActiveSupport::Concern

  # The set `S` of in-scope account ids.
  #   • privat    → the personal (non-shared) accounts.
  #   • gemeinsam → the shared account(s) — the joint household pot.
  # Fallback: when the user has NO shared account the gemeinsam lens would be empty,
  # but the frontend hides the switch and pins to it (ScopeSwitch returns null when
  # !hasShared), so a single-account install would then see an empty dashboard. In
  # that case the lens collapses to ALL accounts (== personal, since none are shared).
  def scoped_account_ids
    accts = Current.user.accounts
    return accts.personal.pluck(:id) if params[:scope] == "privat"

    # gemeinsam: the shared (joint) account(s). One query in the common case; the fallback
    # pluck runs ONLY when there are no shared accounts (lens collapses to ALL == personal).
    ids = accts.shared.pluck(:id)
    ids.presence || accts.pluck(:id)
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
