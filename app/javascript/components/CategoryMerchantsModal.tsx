import { useEffect, useState } from 'react'
import { api } from '../lib/api'
import { withScope, type Scope } from '../lib/scope'
import { formatAmount } from '../lib/format'
import { Modal, Amount, Btn, catColor, hueFor } from './ui'
import { RankedBars, type RankedItem } from './charts'
import type { StatMerchants } from '../lib/types'

const TOP_MERCHANTS = 8 // initial slice; "+N weitere" reveals the rest (server cap is 12)

// A per-category Empfänger ranked-bar row. `id` is ONLY a React key; the genuine null-bucket
// flag is the explicit `merchantName` (null ⇒ the leaf sends creditor="") — never overload
// the label string as the drill key, or a creditor literally named "unnamed" would be
// misrouted (review m1).
type PayeeRow = RankedItem & { merchantName: string | null }

// Level-1 of the Ausgaben drill: one category's top Empfänger, ranked by spend
// (#merchants?category_id|uncategorized over the SAME clamped window as the bar — CM1). A
// click on a payee escalates to the leaf (CategoryFlowsModal with `creditor`, CM2). Same
// chrome as CategoryFlowsModal; footer = the per-category Empfänger total under the DISTINCT
// "Ausgaben mit Empfänger" label (it drops person-transfers, so it legitimately diverges from
// the category "Ausgaben" total — CM1 — and must be labelled apart).
export default function CategoryMerchantsModal({ categoryId, uncategorized, categoryName, from, to, scope, locale, t, onPayee, onClose }: {
  categoryId: number | null
  uncategorized: boolean
  categoryName: string | null   // modal title (the category)
  from: string                  // data.range.from (CLAMPED — CM1 / §1.6)
  to: string                    // data.range.to
  scope: Scope
  locale: string
  t: (k: string, o?: Record<string, unknown>) => string
  onPayee: (p: { creditor: string | null; label: string }) => void  // escalate to the leaf
  onClose: () => void
}) {
  const [data, setData] = useState<StatMerchants | null>(null)
  const [status, setStatus] = useState<'loading' | 'ready' | 'error'>('loading')
  const [showAll, setShowAll] = useState(false)

  useEffect(() => {
    let alive = true
    const qs = new URLSearchParams({ from, to })
    if (uncategorized) qs.set('uncategorized', '1')
    else if (categoryId != null) qs.set('category_id', String(categoryId))
    api(`/api/v1/statistics/merchants?${withScope(qs, scope).toString()}`)
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

  // Map merchant items → RankedItem, carrying the genuine null bucket as the explicit
  // merchantName flag (null ⇒ the leaf sends creditor=""); a creditor literally named
  // "unnamed" round-trips its real name (review m1).
  const rows: PayeeRow[] = (data?.items ?? []).map((m, i) => ({
    id: m.name ?? `__null__${i}`,
    merchantName: m.name,
    label: m.name || t('statistics.merchant.unnamed'),
    value: parseFloat(m.amount),
    share: m.share,
    color: catColor(hueFor(m.name || 'unnamed')),
  }))
  const max = Math.max(1, ...rows.map(r => Math.abs(r.value)))
  const visible = showAll ? rows : rows.slice(0, TOP_MERCHANTS)
  const hidden = rows.length - visible.length

  // Footer = the per-category Empfänger total under the DISTINCT "Ausgaben mit Empfänger"
  // label — it drops person-transfers (CM1) so it legitimately diverges from the category
  // "Ausgaben" total and must be labelled apart (the m4 reasoning). The total is the
  // UN-capped per-category figure, so no per-row count is shown beside it (the items are
  // capped at TOP_MERCHANTS server-side; a capped count next to an un-capped total would
  // mislead).
  const footer = data && rows.length > 0 ? (
    <div className="vf-tally">
      <span className="vf-tally-label">{t('statistics.merchant.payee_total')}</span>
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
      {status === 'ready' && rows.length === 0 && (
        <div className="vf-state">{t('statistics.merchant.empty')}</div>
      )}
      {status === 'ready' && rows.length > 0 && (
        <>
          <RankedBars items={visible} maxValue={max} formatValue={v => formatAmount(Math.abs(v))}
            onRowClick={(it) => {
              const r = it as PayeeRow
              onPayee({ creditor: r.merchantName, label: r.label })
            }} />
          {hidden > 0 && (
            <Btn variant="ghost" size="sm" className="mt-2" onClick={() => setShowAll(true)}>
              {t('statistics.cat.more', { n: hidden })}
            </Btn>
          )}
        </>
      )}
    </Modal>
  )
}
