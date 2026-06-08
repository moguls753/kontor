import { useState, useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { api } from '../lib/api'
import { formatDate, formatAmount } from '../lib/format'
import type { RecurringSeries, Transaction, Category } from '../lib/types'
import RecurringScanModal from '../components/RecurringScanModal'
import Icon from '../components/Icon'
import { Amount, Btn, CategoryChip, CpAvatar, Empty, Eyebrow, Select } from '../components/ui'

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

export default function RecurringPage() {
  const { t } = useTranslation()
  const [series, setSeries] = useState<RecurringSeries[]>([])
  const [categories, setCategories] = useState<Category[]>([])
  const [isLoading, setIsLoading] = useState(true)
  const [error, setError] = useState(false)
  const [retryKey, setRetryKey] = useState(0)
  const [showScan, setShowScan] = useState(false)
  const [expandedId, setExpandedId] = useState<number | null>(null)

  // Load categories once (for assignment)
  useEffect(() => {
    api('/api/v1/categories').then(r => r.ok ? r.json() : []).then(setCategories).catch(() => {})
  }, [])

  // Fetch series
  useEffect(() => {
    const controller = new AbortController()
    setIsLoading(true)
    setError(false)
    fetch('/api/v1/recurring?include_transfers=true', {
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
  }, [retryKey])

  const refetch = () => setRetryKey(k => k + 1)

  const patchSeries = async (id: number, body: Record<string, unknown>) => {
    const r = await api(`/api/v1/recurring/${id}`, { method: 'PATCH', body })
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

  // Three töpfe by *type*, not just direction:
  //  • Verträge & Abos  = outgoing commitments (the "don't forget / fixed costs" set)
  //  • Einnahmen        = incoming, external
  //  • Sparen & Transfers = money between your own accounts (transfer-tagged) — secondary
  const isTransfer = (s: RecurringSeries) => s.merchant_type === 'transfer'
  const contracts = series.filter(s => !isTransfer(s) && s.direction === 'outflow')
  const income = series.filter(s => !isTransfer(s) && s.direction === 'inflow')
  const transfers = series.filter(isTransfer)

  const handlers = {
    categories,
    expandedId,
    onToggle: (id: number) => setExpandedId(o => (o === id ? null : id)),
    onConfirm: (id: number) => patchSeries(id, { user_confirmed: true }),
    onDismiss: dismissSeries,
    onCategory: (id: number, cat: string) => patchSeries(id, { category_id: cat }),
  }

  return (
    <div className="page">
      <div className="page-head">
        <h1 className="page-title">{t('recurring.title')}</h1>
        <Btn variant="primary" icon="scan" onClick={() => setShowScan(true)}>
          {t('recurring.scan')}
        </Btn>
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
            <Btn variant="primary" icon="scan" onClick={() => setShowScan(true)}>{t('recurring.scan')}</Btn>
          </Empty>
        </div>
      ) : (
        <>
          {contracts.length > 0 && (
            <Section title={t('recurring.section_contracts')} series={contracts}
              monthly={sectionMonthly(contracts)} delay="delay-1" {...handlers} />
          )}
          {income.length > 0 && (
            <Section title={t('recurring.section_inflows')} series={income}
              monthly={sectionMonthly(income)} delay="delay-2" {...handlers} />
          )}
          {transfers.length > 0 && (
            <Section title={t('recurring.section_savings')} series={transfers}
              monthly={sectionMonthly(transfers)} hint={t('recurring.savings_hint')}
              secondary delay="delay-3" {...handlers} />
          )}
        </>
      )}

      {showScan && (
        <RecurringScanModal onClose={(didDetect) => {
          setShowScan(false)
          if (didDetect) refetch()
        }} />
      )}
    </div>
  )
}

interface SectionProps {
  title: string
  series: RecurringSeries[]
  monthly: number
  categories: Category[]
  expandedId: number | null
  hint?: string
  secondary?: boolean
  delay?: string
  onToggle: (id: number) => void
  onConfirm: (id: number) => void
  onDismiss: (id: number) => void
  onCategory: (id: number, categoryId: string) => void
}

function Section({ title, series, monthly, categories, expandedId, hint, secondary, delay,
  onToggle, onConfirm, onDismiss, onCategory }: SectionProps) {
  const { t } = useTranslation()
  // primary sections are always open; the secondary (Sparen & Transfers) collapses, default closed
  const [sectionOpen, setSectionOpen] = useState(!secondary)
  const currency = series[0]?.currency ?? 'EUR'

  const sum = monthly > 0 && (
    <span className="mono tabular-nums text-ink-muted text-[12px] shrink-0">
      {t('recurring.monthly_sum', { amount: formatAmount(monthly, currency) })}
    </span>
  )

  const head = (
    <div className="flex items-baseline justify-between gap-3 w-full">
      <span className="flex items-baseline gap-2 min-w-0">
        {secondary && (
          <Icon name={sectionOpen ? 'chevronDown' : 'chevronRight'} size={13}
            className="text-ink-faint shrink-0 self-center" />
        )}
        <Eyebrow>{title}</Eyebrow>
        {secondary && (
          <span className="chip shrink-0">{t('recurring.count_entries', { count: series.length })}</span>
        )}
        {hint && <span className="text-ink-faint text-[11px] truncate hidden sm:inline">{hint}</span>}
      </span>
      {sum}
    </div>
  )

  return (
    <section className={'mb-6 animate-in ' + (delay ?? '')}>
      {secondary ? (
        <button type="button" onClick={() => setSectionOpen(o => !o)}
          className="w-full mb-2 focus-inset text-left opacity-75 hover:opacity-100 transition-opacity">
          {head}
        </button>
      ) : (
        <div className="mb-2">{head}</div>
      )}
      {sectionOpen && (
        <div className={'panel overflow-hidden' + (secondary ? ' opacity-[0.82]' : '')}>
          {series.map(s => (
            <SeriesRow
              key={s.id}
              s={s}
              categories={categories}
              open={expandedId === s.id}
              onToggle={() => onToggle(s.id)}
              onConfirm={() => onConfirm(s.id)}
              onDismiss={() => onDismiss(s.id)}
              onCategory={(cat) => onCategory(s.id, cat)}
            />
          ))}
        </div>
      )}
    </section>
  )
}

interface SeriesRowProps {
  s: RecurringSeries
  categories: Category[]
  open: boolean
  onToggle: () => void
  onConfirm: () => void
  onDismiss: () => void
  onCategory: (categoryId: string) => void
}

function SeriesRow({ s, categories, open, onToggle, onConfirm, onDismiss, onCategory }: SeriesRowProps) {
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
              {s.user_confirmed && (
                <span className="badge badge-ok"><span className="dot" />{t('recurring.confirmed')}</span>
              )}
              {s.status === 'ended' && (
                <span className="badge badge-warn"><span className="dot" />{t('recurring.status_ended')}</span>
              )}
            </div>
            <div className="flex items-center gap-2 flex-wrap mt-0.5">
              <span className="chip">{cadenceLabel}</span>
              <CategoryChip name={s.category?.name ?? null} uncategorisedLabel={t('recurring.no_category')} />
              <span className="flex items-center gap-1.5 text-ink-faint text-[11.5px]" title={confidenceLabel}>
                <ConfidenceDot band={s.confidence_band} />
                {confidenceLabel}
              </span>
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
          {s.next_expected_on && (
            <div className="detail-field">
              <Eyebrow>{t('recurring.next_expected')}</Eyebrow>
              <div className="val mono">{formatDate(s.next_expected_on)}</div>
            </div>
          )}
          <div className="detail-field md:col-span-2">
            <Eyebrow>{t('recurring.assign_category')}</Eyebrow>
            <div className="val">
              <Select value={s.category?.id ? String(s.category.id) : ''} onChange={(e) => onCategory(e.target.value)} ariaLabel={t('recurring.assign_category')} className="max-w-[260px]">
                <option value="">{t('recurring.no_category')}</option>
                {categories.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}
              </Select>
            </div>
          </div>
          <div className="detail-field md:col-span-2 flex-row items-center gap-2 mt-1">
            {!s.user_confirmed && (
              <Btn variant="secondary" size="sm" icon="check" onClick={onConfirm}>{t('recurring.confirm')}</Btn>
            )}
            <Btn variant="ghost" size="sm" icon="trash" onClick={onDismiss}>{t('recurring.dismiss')}</Btn>
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
            <div key={tx.id} className="flex items-center justify-between py-1">
              <span className="mono text-ink-faint text-[12px]">{formatDate(tx.booking_date)}</span>
              <Amount value={tx.amount} currency={tx.currency} className="text-[12.5px]" />
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
