import { useEffect, useState } from 'react'
import { api } from '../lib/api'
import { withScope, type Scope } from '../lib/scope'
import { formatAmount, transactionDisplayName } from '../lib/format'
import { Modal, Amount, CategoryChip } from './ui'
import type { StatVariableFlows, Transaction } from '../lib/types'

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
// #variable_transactions), so same-month rows are already contiguous: bucket them
// into month groups preserving that order and sum each month's subtotal.
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

export default function VariableFlowsModal({ kind, scope, locale, t, onClose }: {
  kind: 'income' | 'expenses'
  scope: Scope
  locale: string
  t: (k: string, o?: Record<string, unknown>) => string
  onClose: () => void
}) {
  const [data, setData] = useState<StatVariableFlows | null>(null)
  const [status, setStatus] = useState<'loading' | 'ready' | 'error'>('loading')

  useEffect(() => {
    let alive = true
    const params = withScope(new URLSearchParams({ kind }), scope)
    api(`/api/v1/statistics/variable_transactions?${params.toString()}`)
      .then(async res => {
        if (!res.ok) { if (alive) setStatus('error'); return }
        const json = await res.json()
        if (!alive) return // re-check: cleanup may have run during the parse await
        setData(json)
        setStatus('ready')
      })
      .catch(() => { if (alive) setStatus('error') })
    return () => { alive = false }
  }, [kind, scope])

  const title = t(kind === 'income' ? 'statistics.forecast.variable_modal.title_income' : 'statistics.forecast.variable_modal.title_expenses')
  const groups = data ? groupByMonth(data.transactions) : []

  // Receipt total — the SAME arithmetic the ledger row shows: Σ ÷ N Mt. = Ø.
  const footer = data && data.transactions.length > 0 ? (
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
  ) : undefined

  return (
    <Modal
      title={title}
      subtitle={data ? t('statistics.forecast.variable_modal.subtitle', { n: data.months }) : undefined}
      onClose={onClose}
      closeLabel={t('common.close')}
      footer={footer}
    >
      {status === 'loading' && <div className="vf-state">{t('statistics.forecast.variable_modal.loading')}</div>}
      {status === 'error' && <div className="vf-state">{t('statistics.forecast.variable_modal.error')}</div>}
      {status === 'ready' && data && data.transactions.length === 0 && (
        <div className="vf-state">{t('statistics.forecast.variable_modal.empty')}</div>
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
              <span className="vf-row-name">
                <span className="vf-row-title">{transactionDisplayName(tx)}</span>
                <CategoryChip name={tx.category?.name ?? null} uncategorisedLabel={t('transactions.uncategorized_chip')} />
              </span>
              <Amount value={tx.amount} currency={tx.currency} className="vf-row-amt" />
            </div>
          ))}
        </section>
      ))}
    </Modal>
  )
}
