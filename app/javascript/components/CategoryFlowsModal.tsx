import { useEffect, useState } from 'react'
import { api } from '../lib/api'
import { withScope, type Scope } from '../lib/scope'
import { formatAmount, transactionDisplayName } from '../lib/format'
import { Modal, Amount, CategoryChip } from './ui'
import type { StatCategoryFlows, Transaction } from '../lib/types'

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
// #category_transactions), so same-month rows are already contiguous: bucket them
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

// Drill-through behind ONE Kategorien-tab bar: the individual transactions for the
// given category over the SAME clamped display window/scope as #show (so the footer
// total reconciles to the bar — invariant CI1). A focused near-clone of
// VariableFlowsModal, but the footer is a count+total tally (no average for a category).
export default function CategoryFlowsModal({ categoryId, uncategorized, categoryName, from, to, scope, locale, t, onClose }: {
  categoryId: number | null
  uncategorized: boolean
  categoryName: string | null   // straight from the bar; endpoint also returns it as fallback
  from: string                  // data.range.from (CLAMPED — plan §1.5 CI1 / §1.6)
  to: string                    // data.range.to
  scope: Scope
  locale: string
  t: (k: string, o?: Record<string, unknown>) => string
  onClose: () => void
}) {
  const [data, setData] = useState<StatCategoryFlows | null>(null)
  const [status, setStatus] = useState<'loading' | 'ready' | 'error'>('loading')

  useEffect(() => {
    let alive = true
    const qs = new URLSearchParams({ from, to })
    if (uncategorized) qs.set('uncategorized', '1')
    else if (categoryId != null) qs.set('category_id', String(categoryId))
    api(`/api/v1/statistics/category_transactions?${withScope(qs, scope).toString()}`)
      .then(async res => {
        if (!res.ok) { if (alive) setStatus('error'); return }
        const json = await res.json()
        if (!alive) return // re-check: cleanup may have run during the parse await
        setData(json)
        setStatus('ready')
      })
      .catch(() => { if (alive) setStatus('error') })
    return () => { alive = false }
  }, [categoryId, uncategorized, from, to, scope])

  const title = categoryName ?? t('statistics.cat.uncategorized')
  const groups = data ? groupByMonth(data.transactions) : []

  // Receipt foot — a single reconciling tally (count + Σ), NOT the Σ÷N÷Ø of the
  // variable modal (a category has no run-rate average). Reuses the .vf-tally chrome.
  const footer = data && data.transactions.length > 0 ? (
    <div className="vf-tally">
      <span className="vf-tally-label">{t('statistics.cat_modal.count_total', { n: data.count })}</span>
      <Amount value={data.total} className="vf-tally-sum" />
    </div>
  ) : undefined

  return (
    <Modal
      title={title}
      onClose={onClose}
      closeLabel={t('common.close')}
      footer={footer}
      size="lg"
    >
      {status === 'loading' && <div className="vf-state">{t('statistics.cat_modal.loading')}</div>}
      {status === 'error' && <div className="vf-state">{t('statistics.cat_modal.error')}</div>}
      {status === 'ready' && data && data.transactions.length === 0 && (
        <div className="vf-state">{t('statistics.cat_modal.empty')}</div>
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
