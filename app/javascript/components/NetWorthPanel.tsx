import { useState, useEffect, useMemo } from 'react'
import { api } from '../lib/api'
import { withScope, type Scope } from '../lib/scope'
import { formatAmount } from '../lib/format'
import { AreaSeries, type LineSeries } from './charts'
import { Empty, Btn, DeltaTag } from './ui'
import type { NetWorthData } from '../lib/types'

type T = (k: string, o?: Record<string, unknown>) => string
type NwRange = 'm3' | 'm6' | 'm12' | 'max'
type NwLens = 'total' | 'liquid'
const RANGES: NwRange[] = ['m3', 'm6', 'm12', 'max']
// Roles excluded from "Liquide" — mirrors ScopedAccounts#investment_account_ids on the server,
// so the composition list under the Liquide lens shows exactly the accounts that sum to it.
const ILLIQUID_ROLES = new Set(['investment', 'sparkonto'])

function rangeFrom(r: NwRange): string | undefined {
  if (r === 'max') return undefined
  const months = r === 'm3' ? 3 : r === 'm6' ? 6 : 12
  const d = new Date()
  d.setMonth(d.getMonth() - months)
  return d.toISOString().slice(0, 10)
}

// Net-worth-over-time for whichever scope the global Familie/Privat switch selects; no
// per-account isolation (PayPal ≈ €0, the broker is a flat pedestal, the card is a liability).
// Liquide (cash you can spend) and Gesamt (incl. investments/savings) are shown SEPARATELY —
// a [Gesamt | Liquide] toggle, one line at a time, never overlaid.
export default function NetWorthPanel({ scope, locale, t }: { scope: Scope; locale: string; t: T }) {
  const [range, setRange] = useState<NwRange>('max')
  const [lens, setLens] = useState<NwLens>('liquid')
  const [data, setData] = useState<NetWorthData | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(false)

  // Own fetch lifecycle (its own range; re-fetches when the global scope flips).
  const fetchNw = async () => {
    setLoading(true)
    setError(false)
    try {
      const from = rangeFrom(range)
      const params = withScope(new URLSearchParams(from ? { from } : {}), scope)
      const res = await api(`/api/v1/net_worth?${params.toString()}`)
      if (res.ok) setData(await res.json())
      else setError(true)
    } catch {
      setError(true)
    } finally {
      setLoading(false)
    }
  }
  useEffect(() => { fetchNw() }, [scope, range]) // eslint-disable-line react-hooks/exhaustive-deps

  const fmt = (v: number) => formatAmount(v)
  const fmtAxis = useMemo(() => {
    const f = new Intl.NumberFormat(locale, { notation: 'compact', maximumFractionDigits: 1 })
    return (v: number) => f.format(v)
  }, [locale])

  const series = data?.series ?? []
  // Liquide differs from Gesamt only when an investment/savings account is in scope. When they
  // coincide, the toggle is meaningless — hide it and pin the (single) Gesamt line.
  const hasSplit = series.some(p => p.total !== p.liquid)
  const activeLens: NwLens = hasSplit ? lens : 'total'
  const isLiquid = activeLens === 'liquid'

  // One line at a time — Gesamt in brass, Liquide in ink. Never both at once.
  const line: LineSeries = useMemo(() => ({
    key: activeLens,
    label: t(isLiquid ? 'statistics.networth.liquid' : 'statistics.networth.total'),
    color: isLiquid ? 'var(--ink)' : 'var(--brass)',
    emphasis: true,
    points: series.map(p => ({ date: p.date, value: parseFloat(isLiquid ? p.liquid : p.total) })),
  }), [series, activeLens, isLiquid, t])

  const latest = parseFloat((isLiquid ? data?.latest.liquid : data?.latest.total) ?? '0')
  const pts = line.points
  const first = pts[0]?.value ?? 0
  const last = pts[pts.length - 1]?.value ?? latest
  const delta = last - first
  const deltaPct = first !== 0 ? (delta / Math.abs(first)) * 100 : null
  // Baseline month of the visible range (the first point) — labels the Gesamt delta so it is
  // never an unlabelled number ("seit <Monat>"). The delta is shown only on Gesamt; on Liquide
  // the change-over-range is cash-flow noise that just depends on where the window starts.
  const sinceMonth = series.length
    ? new Intl.DateTimeFormat(locale, { month: 'short', year: '2-digit' }).format(new Date(series[0].date))
    : null

  const composition = (data?.composition ?? [])
    .filter(c => parseFloat(c.balance) !== 0)
    .filter(c => !isLiquid || !ILLIQUID_ROLES.has(c.role ?? '')) // Liquide lists only the liquid accounts
    .sort((a, b) => Math.abs(parseFloat(b.balance)) - Math.abs(parseFloat(a.balance)))
  // The "investment held flat" caveat only applies to Gesamt — Liquide excludes the broker.
  const showInvestmentCaveat = !isLiquid && composition.some(c => c.role === 'investment')

  return (
    <div className="panel">
      <div className="panel-head">
        <h2 className="section-title">{t('statistics.networth.heading')}</h2>
        <div className="panel-head-side">
          {!loading && !error && series.length > 0 && hasSplit && (
            <div className="segmented" role="group" aria-label={t('statistics.networth.lens.label')}>
              <button className={!isLiquid ? 'on' : ''} aria-pressed={!isLiquid} onClick={() => setLens('total')}>
                {t('statistics.networth.total')}
              </button>
              <button className={isLiquid ? 'on' : ''} aria-pressed={isLiquid} onClick={() => setLens('liquid')}>
                {t('statistics.networth.liquid')}
              </button>
            </div>
          )}
          {!loading && !error && series.length > 0 && (
            <div className="segmented nw-range" role="group" aria-label={t('statistics.networth.range.label')}>
              {RANGES.map(r => (
                <button key={r} className={range === r ? 'on' : ''} aria-pressed={range === r} onClick={() => setRange(r)}>
                  {t(`statistics.networth.range.${r}`)}
                </button>
              ))}
            </div>
          )}
        </div>
      </div>
      <div className="panel-pad">
        {loading ? (
          <div className="nw-state">{t('common.loading')}</div>
        ) : error ? (
          <div className="nw-state">
            <span className="text-danger">{t('common.load_error')}</span>
            <Btn variant="secondary" size="sm" icon="sync" onClick={fetchNw}>{t('common.retry')}</Btn>
          </div>
        ) : !series.length ? (
          <Empty icon="statistics" title={t('statistics.networth.empty_title')} body={t('statistics.networth.empty_body')} />
        ) : (
          <>
            <AreaSeries series={[line]} locale={locale} formatValue={fmt} formatAxis={fmtAxis} />
            <div className="stat-context">
              <span>{t(isLiquid ? 'statistics.networth.kpi.today_liquid' : 'statistics.networth.kpi.today_total')}</span>
              <span className="stat-context-fig">{fmt(latest)}</span>
              {/* Change-over-range delta only on Gesamt (real net-worth trend); on Liquide it's
                  cash-flow noise. Carries a "seit <Monat>" baseline so it's never unlabelled. */}
              {!isLiquid && (
                <>
                  <DeltaTag delta={delta} pct={deltaPct} good="up" formatValue={fmt} locale={locale} ariaLabel={t('statistics.networth.kpi.change')} />
                  {sinceMonth && <span className="nw-since">{t('statistics.networth.since', { month: sinceMonth })}</span>}
                </>
              )}
            </div>
            {composition.length > 1 && (
              <div className="nw-compose">
                <span className="nw-compose-lead">{t('statistics.networth.composition_label')}</span>
                {composition.map((c, i) => (
                  <span className="nw-compose-item" key={i}>{c.name} <span className="mono">{fmt(parseFloat(c.balance))}</span></span>
                ))}
              </div>
            )}
            {showInvestmentCaveat && <p className="nw-caveat">{t('statistics.networth.caveat.investment_flat')}</p>}
          </>
        )}
      </div>
    </div>
  )
}
