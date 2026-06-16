import { useState, useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { api } from '../lib/api'
import { useScope, withScope } from '../lib/scope'
import { formatDate, formatAmount } from '../lib/format'
import type { RecurringSeries, Transaction } from '../lib/types'
import RecalculateButton from '../components/RecalculateButton'
import Icon from '../components/Icon'
import { Amount, Btn, CategoryChip, CpAvatar, Empty, Eyebrow } from '../components/ui'

const CADENCE_KEYS = ['weekly', 'biweekly', 'monthly', 'quarterly', 'yearly', 'irregular']

// Cadence → monthly multiplier, so each topf shows an honest "≈ X/Monat" subtotal
// (a normalised sum of the list you're looking at — not a statistics module).
const MONTHLY_FACTOR: Record<string, number> = {
  weekly: 52 / 12,
  biweekly: 26 / 12,
  monthly: 1,
  quarterly: 1 / 3,
  yearly: 1 / 12,
}
const monthlyEquivalent = (s: RecurringSeries) =>
  (Math.abs(parseFloat(s.expected_amount ?? '0')) || 0) * (MONTHLY_FACTOR[s.cadence] ?? 1)
const sectionMonthly = (list: RecurringSeries[]) => list.reduce((sum, s) => sum + monthlyEquivalent(s), 0)

// A transfer between your own accounts is detected as TWO series — the +X leg and the
// −X leg of the same movement. Merge those mirror legs (same name + same |amount|) into
// one neutral row so the list shows the movement once, not twice.
interface TransferGroup {
  key: string
  canonical_name: string
  currency: string
  cadence: string
  amount: number // absolute
  confidence_band: 'high' | 'medium' | 'low'
  next_expected_on: string | null
  status: 'active' | 'ended' // 'ended' only once BOTH legs are ended (mirrors SeriesRow gating)
  legs: RecurringSeries[]
}
const groupTransfers = (list: RecurringSeries[]): TransferGroup[] => {
  const map = new Map<string, RecurringSeries[]>()
  for (const s of list) {
    const amt = (Math.abs(parseFloat(s.expected_amount ?? '0')) || 0).toFixed(2)
    const k = `${s.canonical_name}::${amt}`
    ;(map.get(k) ?? map.set(k, []).get(k)!).push(s)
  }
  return [...map.entries()].map(([key, legs]) => {
    const rep = legs[0]
    return {
      key,
      canonical_name: rep.canonical_name,
      currency: rep.currency,
      cadence: rep.cadence,
      amount: Math.abs(parseFloat(rep.expected_amount ?? '0')) || 0,
      confidence_band: rep.confidence_band,
      next_expected_on: legs.map(l => l.next_expected_on).filter(Boolean).sort()[0] ?? null,
      status: legs.every(l => l.status === 'ended') ? 'ended' : 'active',
      legs,
    }
  })
}

export default function RecurringPage() {
  const { t } = useTranslation()
  const { scope } = useScope()
  const [series, setSeries] = useState<RecurringSeries[]>([])
  const [isLoading, setIsLoading] = useState(true)
  const [error, setError] = useState(false)
  const [retryKey, setRetryKey] = useState(0)
  const [expandedId, setExpandedId] = useState<number | null>(null)
  const [activeTab, setActiveTab] = useState<string | null>(null)

  // Fetch series
  useEffect(() => {
    const controller = new AbortController()
    setIsLoading(true)
    setError(false)
    const params = withScope(new URLSearchParams({ include_transfers: 'true' }), scope)
    fetch(`/api/v1/recurring?${params}`, {
      headers: { 'Accept': 'application/json' },
      signal: controller.signal,
    })
      .then(async r => {
        if (r.ok) {
          const data = await r.json()
          setSeries(data.series)
        } else {
          setError(true)
        }
      })
      .catch(e => {
        if (e.name !== 'AbortError') setError(true)
      })
      .finally(() => setIsLoading(false))

    return () => controller.abort()
  }, [retryKey, scope])

  const refetch = () => setRetryKey(k => k + 1)

  const patchSeries = async (id: number, body: Record<string, unknown>) => {
    // Send the active lens so the PATCH response's flow_bucket stays scope-aware — otherwise an
    // edited cross-scope transfer (e.g. rent share) would jump back to "Umbuchung" under Privat.
    const qs = withScope(new URLSearchParams(), scope).toString()
    const r = await api(`/api/v1/recurring/${id}${qs ? `?${qs}` : ''}`, { method: 'PATCH', body })
    if (r.ok) {
      const updated: RecurringSeries = await r.json()
      setSeries(list => list.map(s => (s.id === id ? updated : s)))
    }
  }

  const dismissSeries = async (id: number) => {
    const r = await api(`/api/v1/recurring/${id}`, { method: 'DELETE' })
    if (r.ok || r.status === 204) {
      setSeries(list => list.filter(s => s.id !== id))
      if (expandedId === id) setExpandedId(null)
    }
  }

  // Three töpfe by *flow_bucket* (derived server-side), split on UNAMBIGUOUS signals only —
  // direction + own-account membership. No "is this savings?" guessing (dropped: it forced
  // awkward calls on Scalable / Mila / Ansparen). One TAB each:
  //  • Ausgaben  = everything recurring going out (contracts, subscriptions, savings plans)
  //  • Einnahmen = everything recurring coming in, external
  //  • Transfers = pure liquidity moves between your OWN accounts (net-zero)
  const expenses = series.filter(s => s.flow_bucket === 'expense')
  const income = series.filter(s => s.flow_bucket === 'income')
  const transfers = series.filter(s => s.flow_bucket === 'transfer')

  // One tab per non-empty topf — each carries its OWN monthly figure (no global net/saldo).
  // sign: outflow −, inflow +, transfers 0 (net-zero → neutral).
  // mixed: a tab spanning >1 currency can't be summed under one symbol → show a note instead.
  const meta = (key: string, label: string, list: RecurringSeries[], sign: number, hint?: string) => ({
    key, label, list, sign, hint,
    monthly: sectionMonthly(list),
    currency: list[0]?.currency ?? 'EUR',
    mixed: new Set(list.map(s => s.currency)).size > 1,
  })
  const tabs = [
    meta('expenses', t('recurring.section_expenses'), expenses, -1),
    meta('income', t('recurring.section_inflows'), income, 1),
    meta('transfers', t('recurring.section_transfers'), transfers, 0, t('recurring.transfers_hint')),
  ].filter(tab => tab.list.length > 0)
  const activeKey = tabs.some(tb => tb.key === activeTab) ? activeTab : tabs[0]?.key
  const active = tabs.find(tb => tb.key === activeKey)
  const colsClass = ['', 'sm:grid-cols-1', 'sm:grid-cols-2', 'sm:grid-cols-3', 'sm:grid-cols-4'][tabs.length] ?? 'sm:grid-cols-4'

  // WAI-ARIA tabs: Arrow/Home/End move selection and focus the new tab.
  const onTabKey = (e: { key: string; preventDefault: () => void }) => {
    const i = tabs.findIndex(tb => tb.key === activeKey)
    if (i < 0) return
    let j = i
    if (e.key === 'ArrowRight' || e.key === 'ArrowDown') j = (i + 1) % tabs.length
    else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') j = (i - 1 + tabs.length) % tabs.length
    else if (e.key === 'Home') j = 0
    else if (e.key === 'End') j = tabs.length - 1
    else return
    e.preventDefault()
    const key = tabs[j].key
    setActiveTab(key)
    document.getElementById(`rec-tab-${key}`)?.focus()
  }

  return (
    <div className="page">
      <div className="page-head">
        <h1 className="page-title">{t('recurring.title')}</h1>
        <RecalculateButton label={t('common.recalculate_analyze')} onStarted={refetch} />
      </div>

      {error ? (
        <div className="panel">
          <div className="panel-pad flex items-center justify-between gap-3">
            <span className="text-danger text-[13.5px]">{t('common.load_error')}</span>
            <Btn variant="secondary" size="sm" icon="sync" onClick={refetch}>{t('common.retry')}</Btn>
          </div>
        </div>
      ) : isLoading ? (
        <div className="panel">
          <div className="text-ink-muted text-[13.5px] text-center px-5 py-10">{t('common.loading')}</div>
        </div>
      ) : series.length === 0 ? (
        <div className="panel">
          <Empty icon="recurring" title={t('recurring.empty_title')} body={t('recurring.empty_description')}>
            <RecalculateButton label={t('common.recalculate_analyze')} onStarted={refetch} />
          </Empty>
        </div>
      ) : (
        <>
          {/* Tabs: one equal-width card per topf, each showing its own monthly figure.
              The card IS the tab — clicking switches the list below. */}
          <div role="tablist" aria-label={t('recurring.title')} onKeyDown={onTabKey}
            className={`grid gap-3 mb-7 grid-cols-1 ${colsClass} animate-in`}>
            {tabs.map(tab => {
              const on = tab.key === activeKey
              return (
                <button key={tab.key} id={`rec-tab-${tab.key}`} type="button"
                  role="tab" aria-selected={on} aria-controls="rec-tabpanel" tabIndex={on ? 0 : -1}
                  onClick={() => setActiveTab(tab.key)}
                  className={'text-left border-2 rounded-md px-4 py-3 transition-colors focus-inset ' +
                    (on ? 'border-brass bg-brass-soft' : 'border-line hover:border-ink-faint')}>
                  <div className="flex items-center justify-between gap-2">
                    <Eyebrow>{tab.label}</Eyebrow>
                    <span className="chip shrink-0">
                      {tab.key === 'transfers' ? groupTransfers(tab.list).length : tab.list.length}
                    </span>
                  </div>
                  <div className="mt-2 flex items-baseline gap-1.5 flex-wrap min-h-[1.7em]">
                    {tab.sign === 0 ? (
                      // net-zero own-account moves: no euro subtotal (the abs sum would
                      // mislead) — neutral note wins even across mixed currencies
                      <span className="text-ink-muted text-[13px]">{t('recurring.transfers_neutral')}</span>
                    ) : tab.mixed ? (
                      <span className="text-ink-muted text-[13px]">{t('recurring.summary_mixed')}</span>
                    ) : (
                      <>
                        <Amount value={tab.sign * tab.monthly} currency={tab.currency} className="text-[19px]" />
                        <span className="text-ink-faint text-[11px]">{t('recurring.summary_per_month')}</span>
                      </>
                    )}
                  </div>
                </button>
              )
            })}
          </div>

          {active && (
            <div role="tabpanel" id="rec-tabpanel" aria-labelledby={`rec-tab-${activeKey}`}
              tabIndex={0} key={activeKey} className="animate-in delay-1 focus-inset">
              {active.hint && <p className="text-ink-faint text-[12px] mb-2">{active.hint}</p>}
              <div className="panel overflow-hidden">
                {active.key === 'transfers' ? (
                  groupTransfers(active.list).map(g => (
                    <TransferRow key={g.key} g={g}
                      open={expandedId === g.legs[0].id}
                      onToggle={() => setExpandedId(o => (o === g.legs[0].id ? null : g.legs[0].id))}
                      onEnd={() => g.legs.forEach(l => patchSeries(l.id, { status: 'ended' }))}
                      onDismiss={() => g.legs.forEach(l => dismissSeries(l.id))} />
                  ))
                ) : (
                  active.list.map(s => (
                    <SeriesRow key={s.id} s={s}
                      open={expandedId === s.id}
                      onToggle={() => setExpandedId(o => (o === s.id ? null : s.id))}
                      onEnd={() => patchSeries(s.id, { status: 'ended' })}
                      onDismiss={() => dismissSeries(s.id)} />
                  ))
                )}
              </div>
            </div>
          )}
        </>
      )}
    </div>
  )
}

interface SeriesRowProps {
  s: RecurringSeries
  open: boolean
  onToggle: () => void
  onEnd: () => void
  onDismiss: () => void
}

function SeriesRow({ s, open, onToggle, onEnd, onDismiss }: SeriesRowProps) {
  const { t } = useTranslation()
  const sign = s.direction === 'outflow' ? -1 : 1
  const cadenceLabel = CADENCE_KEYS.includes(s.cadence)
    ? t(`recurring.cadence_${s.cadence}`)
    : s.cadence
  const confidenceLabel = t(`recurring.confidence_${s.confidence_band}`)

  return (
    <div className="ledger-row-wrap">
      <button className={'ledger-row focus-inset' + (open ? ' open' : '')}
        onClick={onToggle} aria-expanded={open}>
        <div className="ledger-cp">
          <CpAvatar name={s.canonical_name} sign={sign} />
          <div className="min-w-0">
            <div className="cp-name flex items-center gap-2">
              {s.canonical_name}
              {s.status === 'ended' && (
                <span className="badge badge-warn"><span className="dot" />{t('recurring.status_ended')}</span>
              )}
              {/* A still-active series whose next charge is past the grace window is
                  "überfällig/pausiert". reconcile_vanished auto-ends it on the next detect, so
                  this surfaces only transiently (between going past-grace and the next run). */}
              {s.status === 'active' && s.overdue && (
                <span className="badge badge-warn"><span className="dot" />{t('recurring.overdue')}</span>
              )}
            </div>
            <div className="flex items-center gap-2 flex-wrap mt-0.5">
              <span className="chip">{cadenceLabel}</span>
              <CategoryChip name={s.category?.name ?? null} uncategorisedLabel={t('recurring.no_category')} />
              {/* confidence is NOT shown in the collapsed row (kept light); see expand */}
            </div>
          </div>
        </div>
        <div className="flex flex-col items-end gap-0.5 shrink-0">
          {s.amount_variable && s.amount_min != null && s.amount_max != null ? (
            <span className={`amt ${s.direction === 'inflow' ? 'amt-pos' : 'amt-neg'} text-[14.5px] flex items-center gap-1`}>
              <Amount value={Math.abs(parseFloat(s.amount_min))} currency={s.currency} signed={false} className="text-[14.5px]" />
              <span className="text-ink-faint">–</span>
              <Amount value={Math.abs(parseFloat(s.amount_max))} currency={s.currency} signed={false} className="text-[14.5px]" />
            </span>
          ) : (
            <Amount value={s.expected_amount} currency={s.currency} className="text-[14.5px]" />
          )}
          {s.next_expected_on && (
            <span className="text-ink-faint text-[11.5px]">
              {t('recurring.next_charge')}: <span className="mono">{formatDate(s.next_expected_on)}</span>
            </span>
          )}
        </div>
        <span className="ledger-expand"><Icon name="chevronRight" size={16} className="chev" /></span>
      </button>

      {open && (
        <div className="ledger-detail">
          <div className="detail-field">
            <Eyebrow>{t('recurring.expected')}</Eyebrow>
            <div className="val">
              {s.amount_variable ? t('recurring.variable_amount') : null}
              {!s.amount_variable && <Amount value={s.expected_amount} currency={s.currency} />}
            </div>
          </div>
          <div className="detail-field">
            <Eyebrow>{t('recurring.occurrences', { count: s.occurrences_count })}</Eyebrow>
            <div className="val mono">{s.occurrences_count}</div>
          </div>
          <div className="detail-field">
            <Eyebrow>{t('recurring.confidence')}</Eyebrow>
            <div className="val flex items-center gap-1.5"><ConfidenceDot band={s.confidence_band} />{confidenceLabel}</div>
          </div>
          {s.next_expected_on && (
            <div className="detail-field">
              <Eyebrow>{t('recurring.next_expected')}</Eyebrow>
              <div className="val mono">{formatDate(s.next_expected_on)}</div>
            </div>
          )}
          {/* Category is read-only here — it belongs to the underlying transactions
              (set on the Transactions page); editing it on the series would only diverge
              the label from the actual rows and changes nothing else. */}
          <div className="detail-field md:col-span-2 flex-row items-center gap-2 mt-1">
            {/* P4 — "Beendet": reversible manual stop (PATCH status:ended). STOP icon, not trash:
                the series keeps its history and auto-revives if the pattern recurs. */}
            {s.status === 'active' && (
              <Btn variant="ghost" size="sm" icon="stop" onClick={onEnd} title={t('recurring.mark_ended_hint')}>
                {t('recurring.mark_ended')}
              </Btn>
            )}
            {/* "Nicht wiederkehrend": permanent false-positive reject (DELETE → dismissed). */}
            <Btn variant="ghost" size="sm" icon="close" onClick={onDismiss} title={t('recurring.not_recurring_hint')}>
              {t('recurring.not_recurring')}
            </Btn>
          </div>
          <SeriesMembers seriesId={s.id} open={open} />
        </div>
      )}
    </div>
  )
}

function ConfidenceDot({ band }: { band: 'high' | 'medium' | 'low' }) {
  const cls = band === 'high' ? 'bg-income' : band === 'medium' ? 'bg-brass' : 'bg-ink-faint'
  return <span className={'w-[7px] h-[7px] rounded-full ' + cls} />
}

// One row per own-account movement (mirror +X/−X legs merged). Neutral amount (it nets to
// zero), expand shows the individual legs; confirm/dismiss fan out to all legs of the pair.
function TransferRow({ g, open, onToggle, onEnd, onDismiss }: {
  g: TransferGroup
  open: boolean
  onToggle: () => void
  onEnd: () => void
  onDismiss: () => void
}) {
  const { t } = useTranslation()
  const cadenceLabel = CADENCE_KEYS.includes(g.cadence) ? t(`recurring.cadence_${g.cadence}`) : g.cadence
  const confidenceLabel = t(`recurring.confidence_${g.confidence_band}`)

  return (
    <div className="ledger-row-wrap">
      <button className={'ledger-row focus-inset' + (open ? ' open' : '')}
        onClick={onToggle} aria-expanded={open}>
        <div className="ledger-cp">
          <CpAvatar name={g.canonical_name} sign={0} />
          <div className="min-w-0">
            <div className="cp-name flex items-center gap-2">
              {g.canonical_name}
              {g.legs.length > 1 && (
                <span className="chip" title={t('recurring.transfer_pair')} aria-label={t('recurring.transfer_pair')}>↔</span>
              )}
              {g.status === 'ended' && (
                <span className="badge badge-warn"><span className="dot" />{t('recurring.status_ended')}</span>
              )}
            </div>
            <div className="flex items-center gap-2 flex-wrap mt-0.5">
              <span className="chip">{cadenceLabel}</span>
              {/* confidence shown on expand, not in the collapsed row */}
            </div>
          </div>
        </div>
        <div className="flex flex-col items-end gap-0.5 shrink-0">
          {/* own-account movement nets to zero → show the absolute amount, muted/neutral */}
          <span className="amt amt-null mono text-[14.5px]">{formatAmount(g.amount, g.currency)}</span>
          {g.next_expected_on && (
            <span className="text-ink-faint text-[11.5px]">
              {t('recurring.next_charge')}: <span className="mono">{formatDate(g.next_expected_on)}</span>
            </span>
          )}
        </div>
        <span className="ledger-expand"><Icon name="chevronRight" size={16} className="chev" /></span>
      </button>

      {open && (
        <div className="ledger-detail">
          {g.legs.map(leg => (
            <div className="detail-field" key={leg.id}>
              <Eyebrow>{leg.direction === 'inflow' ? t('recurring.transfer_in') : t('recurring.transfer_out')}</Eyebrow>
              <div className="val"><Amount value={leg.expected_amount} currency={leg.currency} /></div>
            </div>
          ))}
          <div className="detail-field">
            <Eyebrow>{t('recurring.confidence')}</Eyebrow>
            <div className="val flex items-center gap-1.5"><ConfidenceDot band={g.confidence_band} />{confidenceLabel}</div>
          </div>
          <div className="detail-field md:col-span-2 flex-row items-center gap-2 mt-1">
            {/* "Beendet": reversible manual stop, fanned out to BOTH legs (PATCH status:ended).
                The transfer keeps its history and auto-revives if the movement recurs. */}
            {g.status === 'active' && (
              <Btn variant="ghost" size="sm" icon="stop" onClick={onEnd} title={t('recurring.mark_ended_hint')}>
                {t('recurring.mark_ended')}
              </Btn>
            )}
            <Btn variant="ghost" size="sm" icon="close" onClick={onDismiss} title={t('recurring.not_recurring_hint')}>
              {t('recurring.not_recurring')}
            </Btn>
          </div>
        </div>
      )}
    </div>
  )
}

function SeriesMembers({ seriesId, open }: { seriesId: number; open: boolean }) {
  const { t } = useTranslation()
  const [members, setMembers] = useState<Transaction[] | null>(null)
  const [loading, setLoading] = useState(false)

  useEffect(() => {
    if (!open || members !== null) return
    const controller = new AbortController()
    setLoading(true)
    fetch(`/api/v1/recurring/${seriesId}`, {
      headers: { 'Accept': 'application/json' },
      signal: controller.signal,
    })
      .then(r => r.ok ? r.json() : null)
      .then(data => { if (data) setMembers(data.transactions ?? []) })
      .catch(e => { if (e.name !== 'AbortError') setMembers([]) })
      .finally(() => setLoading(false))
    return () => controller.abort()
  }, [open, seriesId, members])

  return (
    <div className="detail-field md:col-span-2 border-t border-line pt-3 mt-1">
      <Eyebrow>{t('recurring.members_title')}</Eyebrow>
      {loading ? (
        <div className="text-ink-muted text-[12.5px] py-1">{t('recurring.members_loading')}</div>
      ) : !members || members.length === 0 ? (
        <div className="text-ink-faint text-[12.5px] py-1">{t('recurring.members_empty')}</div>
      ) : (
        <div className="mt-1">
          {members.map(tx => (
            <div key={tx.id} className="flex items-center justify-between gap-3 py-1">
              <span className="mono text-ink-faint text-[12px] shrink-0">{formatDate(tx.booking_date)}</span>
              {tx.remittance && (
                <span className="text-ink-faint text-[12px] truncate flex-1 min-w-0 text-left" title={tx.remittance}>
                  {tx.remittance}
                </span>
              )}
              <Amount value={tx.amount} currency={tx.currency} className="text-[12.5px] shrink-0" />
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
