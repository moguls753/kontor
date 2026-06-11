// Client-side "Was-wäre-wenn" scenario layer for the forecast (Vorschau). Pure +
// ephemeral: assumptions live in React state + localStorage, never the backend. They
// ride ON TOP of the baseline forecast numbers the API already returns. No persistence
// to the real forecast — this is a playground (see SCENARIO_PLAYGROUND_PLAN.md).

export type ScenarioKind = 'recurring' | 'oneoff'
// 'both'   → income or a real expense: hits Liquide AND Gesamt.
// 'liquid' → money moved to savings/investment: leaves your spendable balance but stays
//            in net worth, so it reduces Liquide ONLY (Gesamt unchanged).
export type ScenarioLens = 'both' | 'liquid'

export interface ScenarioAdjustment {
  id: string
  kind: ScenarioKind
  label: string
  amount: number      // signed delta: + adds money, − removes it (EUR)
  lens: ScenarioLens
  fromOffset: number  // 1..12 months from the current month (1 = next month)
  // Which "Typischer Monat" line a recurring both-lens delta belongs to — the SOURCE
  // direction, NOT the delta sign: lowering rent is +amount but an EXPENSE-line change.
  // Optional (older persisted adjustments fall back to the amount sign).
  bucket?: 'income' | 'expense'
}

const STORAGE_KEY = 'kontor-scenario'

// Self-host may run over plain http:// on a LAN where crypto.randomUUID is undefined.
export function newId(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') return crypto.randomUUID()
  return `s-${Date.now().toString(36)}-${Math.floor(Math.random() * 1e9).toString(36)}`
}

// Parse a German-formatted amount ("1.234,56" / "1234,5" / "40") to a positive number.
// Strips thousands dots/spaces, normalizes comma→dot, drops any sign (the sign is owned
// by the +/− toggle, never the field). Returns NaN if not parseable / zero.
export function parseAmount(input: string): number {
  const cleaned = input.trim().replace(/[\s.]/g, '').replace(',', '.').replace(/[^0-9.]/g, '')
  if (cleaned === '' || cleaned === '.') return NaN
  const n = Number(cleaned)
  return isFinite(n) ? Math.abs(n) : NaN
}

// The next `count` months as { offset, label } — offset 1 = next month. Label localized
// "August 2026" (month long + year, NOT dateStyle, which would add a day). Browser Date
// is fine here (this runs in the browser, not the workflow sandbox).
export function monthOptions(locale: string, count = 12): { offset: number; label: string }[] {
  const fmt = new Intl.DateTimeFormat(locale, { month: 'long', year: 'numeric' })
  const now = new Date()
  const out: { offset: number; label: string }[] = []
  for (let offset = 1; offset <= count; offset++) {
    out.push({ offset, label: fmt.format(new Date(now.getFullYear(), now.getMonth() + offset, 1)) })
  }
  return out
}

// Short month label for an assumption chip ("Aug.", no year).
export function offsetShort(offset: number, locale: string): string {
  const now = new Date()
  return new Intl.DateTimeFormat(locale, { month: 'short' }).format(new Date(now.getFullYear(), now.getMonth() + offset, 1))
}

// Project a balance `horizonMonth` months forward, applying the scenario.
//   column 'liquid' → every adjustment applies (savings leaves your spendable balance).
//   column 'total'  → only lens==='both' adjustments apply (savings stays in net worth).
// No-regression guard: with no ACTIVE adjustment for this column it returns exactly the
// linear baseline (balance + net*h), byte-for-byte — no float drift vs the non-scenario
// render. A recurring +X from offset k contributes (h − k + 1)× at horizon h.
export function projectBalance(
  balanceToday: number,
  baselineNet: number,
  adjustments: ScenarioAdjustment[],
  horizonMonth: number,
  column: 'liquid' | 'total',
): number {
  const active = adjustments.filter(a => column === 'liquid' || a.lens === 'both')
  if (active.length === 0) return balanceToday + baselineNet * horizonMonth

  let bal = balanceToday
  for (let m = 1; m <= horizonMonth; m++) {
    let delta = baselineNet
    for (const a of active) {
      const applies = a.kind === 'recurring' ? m >= a.fromOffset : m === a.fromOffset
      if (applies) delta += a.amount
    }
    bal += delta
  }
  return bal
}

function isValidAdjustment(a: unknown): a is ScenarioAdjustment {
  const o = a as Record<string, unknown>
  return !!o && typeof o === 'object'
    && typeof o.id === 'string'
    && (o.kind === 'recurring' || o.kind === 'oneoff')
    && (o.lens === 'both' || o.lens === 'liquid')
    && typeof o.amount === 'number' && isFinite(o.amount as number)
    && typeof o.fromOffset === 'number' && (o.fromOffset as number) >= 1
    && typeof o.label === 'string'
    && (o.bucket === undefined || o.bucket === 'income' || o.bucket === 'expense')
}

export function loadScenario(): ScenarioAdjustment[] {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    const parsed = raw ? JSON.parse(raw) : []
    return Array.isArray(parsed) ? parsed.filter(isValidAdjustment) : []
  } catch {
    return []
  }
}

export function saveScenario(adjustments: ScenarioAdjustment[]): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(adjustments))
  } catch {
    /* localStorage unavailable (private mode) — playground just won't persist */
  }
}
