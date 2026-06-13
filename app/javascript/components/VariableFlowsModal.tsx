import { useEffect, useState, type ReactNode } from 'react'
import { api } from '../lib/api'
import { withScope, type Scope } from '../lib/scope'
import { formatAmount, transactionDisplayName } from '../lib/format'
import { Modal, Amount, CategoryChip } from './ui'
import type { StatVariableFlows, StatMerchantFlows, Transaction } from '../lib/types'

// "YYYY-MM" → "März 2026" (full month + year), for the receipt section headers.
function monthLabel(monthKey: string, locale: string): string {
  const [y, m] = monthKey.split('-').map(Number)
  return new Intl.DateTimeFormat(locale, { month: 'long', year: 'numeric' }).format(new Date(y, m - 1, 1))
}

// "YYYY-MM-DD" → locale day+month ("05.03." de / "05/03" en-GB); year lives in the
// section header, so it's deliberately omitted here.
function dayMonth(dateStr: string, locale: string): string {
  const [y, m, d] = dateStr.split('-').map(Number)
  return new Intl.DateTimeFormat(locale, { day: '2-digit', month: '2-digit' }).format(new Date(y, m - 1, d))
}

type MonthGroup = { key: string; subtotal: number; rows: Transaction[] }

// The endpoint returns rows booking_date DESC (statistics_controller.rb
// #variable_transactions / #merchants), so same-month rows are already contiguous: bucket
// them into month groups preserving that order and sum each month's subtotal.
function groupByMonth(txs: Transaction[]): MonthGroup[] {
  const groups: MonthGroup[] = []
  for (const tx of txs) {
    const key = tx.booking_date.slice(0, 7)
    let g = groups[groups.length - 1]
    if (!g || g.key !== key) {
      g = { key, subtotal: 0, rows: [] }
      groups.push(g)
    }
    g.rows.push(tx)
    g.subtotal += parseFloat(tx.amount)
  }
  return groups
}

// Drill-through receipt — two modes over ONE component (the prompt requires reusing the
// SAME modal for the merchant drill):
//  • KIND mode (default, `merchant` absent) — the forecast's Variable Einnahmen/Ausgaben
//    average breakdown (#variable_transactions), footer = Σ ÷ N Mt. = Ø.
//  • MERCHANT mode (`merchant` present) — one merchant's transactions over the SAME clamped
//    window the top-merchants LIST used (#merchants?name=&from=&to=), footer = Σ + count (a
//    merchant total is a sum, not an average). The from/to are load-bearing (review B1): with
//    no window the backend defaults to the forecast trailing-6-months → Σ(modal) ≠ row.
// `data` is the discriminated union StatVariableFlows | StatMerchantFlows; the merchant-only
// vs. kind-only reads sit behind the `merchant == null` guard so tsc enforces the branches.
export default function VariableFlowsModal({ kind, merchant, scope, locale, t, onClose }: {
  kind: 'income' | 'expenses'
  merchant?: { name: string; label: string; from: string; to: string }
  scope: Scope
  locale: string
  t: (k: string, o?: Record<string, unknown>) => string
  onClose: () => void
}) {
  const [data, setData] = useState<StatVariableFlows | StatMerchantFlows | null>(null)
  const [status, setStatus] = useState<'loading' | 'ready' | 'error'>('loading')

  useEffect(() => {
    let alive = true
    const url = merchant
      ? `/api/v1/statistics/merchants?${withScope(new URLSearchParams({ name: merchant.name, from: merchant.from, to: merchant.to }), scope).toString()}`
      : `/api/v1/statistics/variable_transactions?${withScope(new URLSearchParams({ kind }), scope).toString()}`
    api(url)
      .then(async res => {
        if (!res.ok) { if (alive) setStatus('error'); return }
        const json = await res.json()
        if (!alive) return // re-check: cleanup may have run during the parse await
        setData(json)
        setStatus('ready')
      })
      .catch(() => { if (alive) setStatus('error') })
    return () => { alive = false }
    // Depend on merchant's primitive fields (not the object identity, which the parent
    // recreates each render) so the fetch doesn't refire on unrelated parent re-renders.
  }, [kind, merchant?.name, merchant?.from, merchant?.to, scope])

  const groups = data ? groupByMonth(data.transactions) : []

  // Title / subtitle / footer all branch on mode (review M2 — the four kind-derived spots:
  // title, subtitle, footer, body/state keys). The merchant response has no months/average,
  // so those reads sit inside `merchant == null` (the discriminated union forces it).
  const title = merchant
    ? merchant.label
    : t(kind === 'income' ? 'statistics.forecast.variable_modal.title_income' : 'statistics.forecast.variable_modal.title_expenses')

  // Subtitle: kind mode derives it from data.months ("gemittelt über N Mt."); merchant mode
  // has no months → no subtitle (gating it avoids interpolating a missing {{n}}). The
  // `'months' in data` check narrows the union to StatVariableFlows for tsc (review M1).
  const subtitle = !merchant && data && 'months' in data
    ? t('statistics.forecast.variable_modal.subtitle', { n: data.months })
    : undefined

  // Footer: kind mode = the Σ ÷ N Mt. = Ø average tally; merchant mode = a Σ + count block
  // under the "Ausgaben mit Empfänger" label (review m4 — a merchant total is a sum). The
  // mode is gated on `merchant`; the `in` checks narrow the discriminated union for tsc.
  let footer: ReactNode = undefined
  if (data && data.transactions.length > 0) {
    if (merchant && 'count' in data) {
      footer = (
        <div className="vf-tally">
          <div className="vf-tally-calc">
            <span className="vf-tally-label">{t('statistics.merchant.payee_total')}</span>
            <span className="vf-tally-op">{t('statistics.merchant.count', { n: data.count })}</span>
          </div>
          <Amount value={data.total} className="vf-tally-sum" />
        </div>
      )
    } else if (!merchant && 'months' in data) {
      footer = (
        <div className="vf-tally">
          <div className="vf-tally-calc">
            <span className="vf-tally-label">{t('statistics.forecast.variable_modal.sum')}</span>
            <Amount value={data.total} className="vf-tally-sum" />
            <span className="vf-tally-op">{t('statistics.forecast.variable_modal.divide', { n: data.months })}</span>
          </div>
          <div className="vf-tally-avg">
            <span className="vf-tally-label">{t('statistics.forecast.variable_modal.average')}</span>
            <Amount value={data.average} className="vf-tally-avg-amt" />
          </div>
        </div>
      )
    }
  }

  return (
    <Modal
      title={title}
      subtitle={subtitle}
      onClose={onClose}
      closeLabel={t('common.close')}
      footer={footer}
      size="lg"
    >
      {status === 'loading' && <div className="vf-state">{t('statistics.forecast.variable_modal.loading')}</div>}
      {status === 'error' && <div className="vf-state">{t('statistics.forecast.variable_modal.error')}</div>}
      {status === 'ready' && data && data.transactions.length === 0 && (
        <div className="vf-state">{t(merchant ? 'statistics.merchant.empty' : 'statistics.forecast.variable_modal.empty')}</div>
      )}
      {status === 'ready' && groups.map(g => (
        <section className="vf-group" key={g.key}>
          <div className="vf-group-head">
            <span className="vf-group-month">{monthLabel(g.key, locale)}</span>
            <span className="vf-group-sub">{formatAmount(g.subtotal)}</span>
          </div>
          {g.rows.map(tx => (
            <div className="vf-row" key={tx.id}>
              <span className="vf-row-date">{dayMonth(tx.booking_date, locale)}</span>
              <span className="vf-row-title">{transactionDisplayName(tx)}</span>
              <CategoryChip name={tx.category?.name ?? null} uncategorisedLabel={t('transactions.uncategorized_chip')} />
              <Amount value={tx.amount} currency={tx.currency} className="vf-row-amt" />
            </div>
          ))}
        </section>
      ))}
    </Modal>
  )
}
