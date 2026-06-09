// Period selection for the Statistics page: maps a preset to a [from, to] date
// range (browser-local; the backend clamps to real data anyway) and formats month
// keys for chart axes.

export type PeriodKey = 'this_month' | 'last_month' | 'm3' | 'm6' | 'm12' | 'ytd'

export const PERIOD_KEYS: PeriodKey[] = ['this_month', 'last_month', 'm3', 'm6', 'm12', 'ytd']

export const DEFAULT_PERIOD: PeriodKey = 'm6'

export interface DateRange { from: string; to: string }

function iso(y: number, mZero: number, d: number): string {
  return `${y}-${String(mZero + 1).padStart(2, '0')}-${String(d).padStart(2, '0')}`
}

export function periodRange(key: PeriodKey, today = new Date()): DateRange {
  const y = today.getFullYear()
  const m = today.getMonth()
  const d = today.getDate()
  const todayIso = iso(y, m, d)
  const firstOfMonthBack = (n: number): string => {
    const dt = new Date(y, m - n, 1)
    return iso(dt.getFullYear(), dt.getMonth(), 1)
  }

  switch (key) {
    case 'this_month':
      return { from: iso(y, m, 1), to: todayIso }
    case 'last_month': {
      const start = new Date(y, m - 1, 1)
      const end = new Date(y, m, 0) // day 0 of this month = last day of previous
      return { from: iso(start.getFullYear(), start.getMonth(), 1), to: iso(end.getFullYear(), end.getMonth(), end.getDate()) }
    }
    case 'm3':
      return { from: firstOfMonthBack(2), to: todayIso }
    case 'm6':
      return { from: firstOfMonthBack(5), to: todayIso }
    case 'm12':
      return { from: firstOfMonthBack(11), to: todayIso }
    case 'ytd':
      return { from: iso(y, 0, 1), to: todayIso }
  }
}

// "YYYY-MM" → short month label; appends a 2-digit year on January so a window
// crossing a year boundary stays unambiguous.
export function formatMonth(monthKey: string, locale: string): string {
  const [y, m] = monthKey.split('-').map(Number)
  const dt = new Date(y, m - 1, 1)
  const label = new Intl.DateTimeFormat(locale, { month: 'short' }).format(dt)
  return m === 1 ? `${label} ’${String(y).slice(2)}` : label
}

export function readPeriod(): PeriodKey {
  if (typeof localStorage === 'undefined') return DEFAULT_PERIOD
  const v = localStorage.getItem('stats-period')
  return (PERIOD_KEYS as string[]).includes(v || '') ? (v as PeriodKey) : DEFAULT_PERIOD
}
