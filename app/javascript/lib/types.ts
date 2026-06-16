export interface Category {
  id: number
  name: string
}

export type AccountRole = 'giro' | 'sparkonto' | 'investment' | 'kreditkarte' | 'zahlung' | 'sonstiges'

export const ACCOUNT_ROLES: AccountRole[] = ['giro', 'sparkonto', 'investment', 'kreditkarte', 'zahlung', 'sonstiges']

export interface DashboardTransaction {
  id: number
  amount: string
  currency: string
  booking_date: string
  remittance: string | null
  creditor_name: string | null
  debtor_name: string | null
  account_name: string
  category: Category | null
}

export interface DashboardAccount {
  id: number
  name: string
  iban: string | null
  balance_amount: string | null
  currency: string
  last_synced_at: string | null
}

export interface DashboardData {
  total_balance: string
  balance_change: string
  balance_change_percent: number | null
  income: string
  expenses: string
  transaction_count: number
  uncategorized_count: number
  accounts: DashboardAccount[]
  recent_transactions: DashboardTransaction[]
}

export interface Transaction {
  id: number
  transaction_id: string
  amount: string
  currency: string
  booking_date: string
  value_date: string | null
  status: string
  remittance: string | null
  creditor_name: string | null
  creditor_iban: string | null
  debtor_name: string | null
  debtor_iban: string | null
  bank_transaction_code: string | null
  category: Category | null
  account_id: number
  account_name: string
}

export interface RecurringSeries {
  id: number
  flow_bucket: 'expense' | 'income' | 'transfer'
  canonical_name: string
  merchant_type: string | null
  direction: 'inflow' | 'outflow'
  cadence: string
  cadence_days: number | null
  expected_amount: string | null
  amount_variable: boolean
  amount_min: string | null
  amount_max: string | null
  currency: string
  confidence: string
  confidence_band: 'high' | 'medium' | 'low'
  status: 'active' | 'ended' | 'dismissed'
  user_confirmed: boolean
  occurrences_count: number
  first_seen_on: string | null
  last_seen_on: string | null
  next_expected_on: string | null
  overdue: boolean
  category: Category | null
}

export interface PaginationMeta {
  page: number
  per: number
  total: number
  total_pages: number
}

export interface TransactionsResponse {
  transactions: Transaction[]
  meta: PaginationMeta
}

export interface BankConnectionSummary {
  id: number
  provider: string
  institution_name: string
}

export interface Account {
  id: number
  account_uid: string
  iban: string | null
  name: string
  role: AccountRole | null
  shared: boolean
  currency: string
  balance_amount: string | null
  balance_type: string | null
  balance_updated_at: string | null
  last_synced_at: string | null
  bank_connection: BankConnectionSummary
}

export interface BankConnectionAccount {
  id: number
  iban: string | null
  name: string
  role: AccountRole | null
  shared: boolean
  currency: string
  balance_amount: string | null
  last_synced_at: string | null
}

export interface BankConnection {
  id: number
  provider: string
  institution_id: string
  institution_name: string
  country_code: string
  status: string
  valid_until: string | null
  last_synced_at: string | null
  error_message: string | null
  accounts: BankConnectionAccount[]
}

export interface CredentialsStatus {
  enable_banking: { configured: boolean; app_id?: string }
  gocardless: { configured: boolean }
  trade_republic: { configured: boolean; phone_number_masked?: string }
  easybank: { configured: boolean; username_masked?: string }
  paypal: { configured: boolean; username_masked?: string }
  llm: { configured: boolean; base_url?: string; llm_model?: string }
}

export interface StatRange {
  from: string
  to: string
  months: number
  clamped: boolean
}

export interface StatKpis {
  income: string
  expenses: string
  net: string
  savings_rate: number | null
  avg_monthly_expenses: string
  fixed_monthly: string
  recurring_payment_count: number
  top_category: { name: string | null; amount: string } | null
}

export interface StatCashflowPoint {
  month: string
  income: string
  expenses: string
  net: string
}

export interface StatFixedVariablePoint {
  month: string
  fixed: string
  variable: string
}

export interface StatCategoryItem {
  id: number | null
  name: string | null
  amount: string
  count: number
  share: number | null
}

export interface StatCategories {
  items: StatCategoryItem[]
  total: string
}

export interface StatForecastItem {
  name: string
  date: string
  amount: string
  direction: 'inflow' | 'outflow'
}

export interface StatForecast {
  recurring_income: string
  recurring_expenses: string
  variable_income: string
  variable_expenses: string
  avg_window_months: number
  current_balance: string
  total_net: string
  liquid_balance: string
  liquid_net: string
  recurring_items: RecurringItem[]
  upcoming: StatForecastItem[]
  upcoming_total: string
}

// A named recurring run-rate (signed: + income, − expense) the scenario playground
// can let the user adjust to a new value.
export interface RecurringItem {
  label: string
  monthly: number
}

export interface StatVariableFlows {
  kind: 'income' | 'expenses'
  range: { from: string; to: string }
  months: number
  total: string
  average: string
  transactions: Transaction[]
}

// Category drill-through response (reuses the shared Transaction type). Σ(transactions.amount)
// reconciles to the matching category bar's amount over the same clamped window (invariant CI1).
export interface StatCategoryFlows {
  category: { id: number | null; name: string | null }
  range: { from: string; to: string }
  total: string
  count: number
  transactions: Transaction[]
}

// Level-1 of the Ausgaben drill: a category's top Empfänger (GET /api/v1/statistics/merchants
// ?category_id|uncategorized). Mirrors StatCategoryItem minus `id`; `name` is null for the
// no-creditor bucket. `total` is the UN-capped PER-CATEGORY figure (the `items` may sum to
// less because of the server-side cap; it also drops person-transfers — invariant CM1).
export interface StatMerchantItem { name: string | null; amount: string; count: number; share: number | null }
export interface StatMerchants { items: StatMerchantItem[]; total: string }

// Verlauf Ø-reference (rides on #show — §3b). Per metric: the LAST COMPLETED month's total
// (`current`), the trailing Ø = mean of the displayed COMPLETED months (`baseline`), their
// `delta`, and `pct` (null when the Ø is zero — no divide-by-zero). `baseline_months` =
// count of completed months averaged; `last_complete_month` = the 'YYYY-MM' the delta is for
// (null when the window has no completed month). All money as BigDecimal strings.
export interface StatDeltaPair { current: string; baseline: string; delta: string; pct: number | null }
export interface StatVsAverage {
  baseline_months: number
  last_complete_month: string | null
  income: StatDeltaPair
  expenses: StatDeltaPair
  net: StatDeltaPair
}

export interface StatisticsData {
  range: StatRange
  transaction_count: number
  kpis: StatKpis
  cashflow: StatCashflowPoint[]
  fixed_variable: StatFixedVariablePoint[]
  categories: StatCategories
  vs_average: StatVsAverage
  forecast: StatForecast
}

// Net-worth-over-time (GET /api/v1/net_worth?scope&from&to). Two aggregate daily lines —
// Liquide (excl. investment/savings) and Gesamt — reconstructed server-side from the
// in-scope accounts' transactions; plus today's composition for a context line. Scope
// (Familie/Privat) is the global switch; the chart just renders what the scope returns.
export interface NetWorthSeriesPoint {
  date: string
  liquid: string
  total: string
}

export interface NetWorthCompositionItem {
  name: string
  role: AccountRole | null
  balance: string
}

export interface NetWorthData {
  range: { from: string; to: string }
  series: NetWorthSeriesPoint[]
  latest: { total: string; liquid: string } // current balances → NW1 dashboard parity
  composition: NetWorthCompositionItem[]
}
