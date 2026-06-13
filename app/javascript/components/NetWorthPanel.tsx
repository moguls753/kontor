import { useState, useEffect, useMemo } from 'react'
import { api } from '../lib/api'
import { withScope, type Scope } from '../lib/scope'
import { formatAmount } from '../lib/format'
import { AreaSeries, Legend, type LineSeries, type LinePoint } from './charts'
import { Empty, Eyebrow, Btn } from './ui'
import type { NetWorthData, NetWorthAccount } from '../lib/types'

type T = (k: string, o?: Record<string, unknown>) => string
type NwRange = 'm3' | 'm6' | 'm12' | 'max'
type Lens = 'both' | 'liquid' | 'total'
const RANGES: NwRange[] = ['m3', 'm6', 'm12', 'max']
const LENSES: Lens[] = ['both', 'liquid', 'total']

function rangeFrom(r: NwRange): string | undefined {
  if (r === 'max') return undefined
  const months = r === 'm3' ? 3 : r === 'm6' ? 6 : 12
  const d = new Date()
  d.setMonth(d.getMonth() - months)
  return d.toISOString().slice(0, 10)
}

// Sum a SUBSET of per-account daily series into one line, clamped to the date where
// every selected account has data (max earliest) — the honest combined start (§2.4).
// Each account's series is dense daily, so a plain date-keyed lookup aligns them.
function composite(accts: NetWorthAccount[]): LinePoint[] {
  if (!accts.length) return []
  const start = accts.reduce((m, a) => (a.earliest > m ? a.earliest : m), accts[0].earliest)
  const maps = accts.map(a => new Map(a.series.map(p => [p.date, parseFloat(p.balance)])))
  const axis = accts.reduce((a, b) => (a.series.length >= b.series.length ? a : b))
  return axis.series
    .filter(p => p.date >= start)
    .map(p => ({ date: p.date, value: maps.reduce((s, m) => s + (m.get(p.date) ?? 0), 0) }))
}

export default function NetWorthPanel({ scope, locale, t }: { scope: Scope; locale: string; t: T }) {
  const [range, setRange] = useState<NwRange>('max')
  const [lens, setLens] = useState<Lens>('both')
  const [isolate, setIsolate] = useState<number | null>(null)
  const [data, setData] = useState<NetWorthData | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(false)

  // Own fetch lifecycle (its own range, decoupled from the page's period/load gates).
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
  // Account ids differ across scopes → drop an isolation that no longer applies.
  useEffect(() => { setIsolate(null) }, [scope])

  const nf1 = useMemo(() => new Intl.NumberFormat(locale, { maximumFractionDigits: 1 }), [locale])
  const fmtAxis = useMemo(() => {
    const f = new Intl.NumberFormat(locale, { notation: 'compact', maximumFractionDigits: 1 })
    return (v: number) => f.format(v)
  }, [locale])
  const fmt = (v: number) => formatAmount(v)
  const signed = (v: number) => (v >= 0 ? '+ ' : '− ') + formatAmount(Math.abs(v))

  const accounts = data?.accounts ?? []
  const hasInvestment = accounts.some(a => a.investment)
  const isolated = isolate != null ? accounts.find(a => a.id === isolate) ?? null : null

  const { lines, primary } = useMemo<{ lines: LineSeries[]; primary: LinePoint[] }>(() => {
    if (!accounts.length) return { lines: [], primary: [] }
    if (isolated) {
      const pts = composite([isolated])
      return { lines: [{ key: 'iso', label: isolated.name, color: 'var(--brass)', emphasis: true, points: pts }], primary: pts }
    }
    const total = composite(accounts)
    const liquid = composite(accounts.filter(a => !a.investment))
    const totalLine: LineSeries = { key: 'total', label: t('statistics.networth.lens.total'), color: 'var(--brass)', emphasis: true, points: total }
    const liquidLine: LineSeries = { key: 'liquid', label: t('statistics.networth.lens.liquid'), color: 'var(--ink)', emphasis: true, points: liquid }
    if (lens === 'liquid') return { lines: [liquidLine], primary: liquid }
    if (lens === 'total' || !hasInvestment) return { lines: [totalLine], primary: total }
    return { lines: [totalLine, { ...liquidLine, emphasis: false }], primary: total }
  }, [accounts, isolated, lens, hasInvestment, t])

  const summary = data?.summary
  // Headline matches the chart's primary line: the isolated account, or — by lens — the
  // liquid vs total live balance. (A hard-wired total would contradict the chart + delta
  // in the Liquid lens.) `delta` is off `primary`, so it already tracks the same line.
  const todayHeadline = isolated
    ? (primary[primary.length - 1]?.value ?? 0)
    : parseFloat((lens === 'liquid' ? summary?.latest.liquid : summary?.latest.total) ?? '0')
  const todayLiquid = parseFloat(summary?.latest.liquid ?? '0')
  const first = primary[0]?.value ?? 0
  const last = primary[primary.length - 1]?.value ?? 0
  const delta = last - first
  const deltaPct = first !== 0 ? (delta / Math.abs(first)) * 100 : null
  // No redundant "Liquid today" when the headline already IS liquid.
  const showLiquidKpi = !isolated && hasInvestment && lens !== 'liquid'
  // The flat-broker note shows only when an investment balance is part of the shown line.
  const showCaveat = isolated ? isolated.investment : lens !== 'liquid' && hasInvestment

  return (
    <div className="panel">
      <div className="panel-head">
        <h2 className="section-title">{t('statistics.networth.heading')}</h2>
        {!loading && !error && accounts.length > 0 && (
          <div className="segmented nw-range" role="group" aria-label={t('statistics.networth.range.label')}>
            {RANGES.map(r => (
              <button key={r} className={range === r ? 'on' : ''} aria-pressed={range === r} onClick={() => setRange(r)}>
                {t(`statistics.networth.range.${r}`)}
              </button>
            ))}
          </div>
        )}
      </div>
      <div className="panel-pad">
        {loading ? (
          <div className="nw-state">{t('common.loading')}</div>
        ) : error ? (
          <div className="nw-state">
            <span className="text-danger">{t('common.load_error')}</span>
            <Btn variant="secondary" size="sm" icon="sync" onClick={fetchNw}>{t('common.retry')}</Btn>
          </div>
        ) : !accounts.length ? (
          <Empty icon="statistics" title={t('statistics.networth.empty_title')} body={t('statistics.networth.empty_body')} />
        ) : (
          <>
            <div className="nw-kpis">
              <div className="nw-kpi">
                <Eyebrow>{isolated ? isolated.name : t(lens === 'liquid' ? 'statistics.networth.kpi.liquid_today' : 'statistics.networth.kpi.today')}</Eyebrow>
                <div className="nw-kpi-fig">{fmt(todayHeadline)}</div>
              </div>
              <div className="nw-kpi">
                <Eyebrow>{t('statistics.networth.kpi.change')}</Eyebrow>
                <div className={'nw-kpi-fig nw-delta ' + (delta >= 0 ? 'pos' : 'neg')}>
                  <span aria-hidden="true" className="nw-delta-arrow">{delta >= 0 ? '▲' : '▼'}</span>
                  {signed(delta)}
                  {deltaPct != null && <span className="nw-delta-pct">{nf1.format(Math.abs(deltaPct))} %</span>}
                </div>
              </div>
              {showLiquidKpi && (
                <div className="nw-kpi">
                  <Eyebrow>{t('statistics.networth.kpi.liquid_today')}</Eyebrow>
                  <div className="nw-kpi-fig nw-kpi-muted">{fmt(todayLiquid)}</div>
                </div>
              )}
            </div>

            <div className="nw-controls">
              {!isolated && hasInvestment && (
                <div className="segmented" role="group" aria-label={t('statistics.networth.lens.label')}>
                  {LENSES.map(l => (
                    <button key={l} className={lens === l ? 'on' : ''} aria-pressed={lens === l} onClick={() => setLens(l)}>
                      {t(`statistics.networth.lens.${l}`)}
                    </button>
                  ))}
                </div>
              )}
              <div className="nw-chips" role="group" aria-label={t('statistics.networth.isolate.label')}>
                <button className={'nw-chip' + (isolate == null ? ' on' : '')} aria-pressed={isolate == null} onClick={() => setIsolate(null)}>
                  {t('statistics.networth.isolate.all')}
                </button>
                {accounts.map(a => (
                  <button key={a.id} className={'nw-chip' + (isolate === a.id ? ' on' : '')} aria-pressed={isolate === a.id} onClick={() => setIsolate(a.id)}>
                    {a.name}
                  </button>
                ))}
              </div>
            </div>

            {lines.length > 1 && <Legend items={lines.map(l => ({ label: l.label, color: l.color }))} />}
            <AreaSeries series={lines} locale={locale} formatValue={fmt} formatAxis={fmtAxis} />

            {showCaveat && <p className="nw-caveat">{t('statistics.networth.caveat.investment_flat')}</p>}
          </>
        )}
      </div>
    </div>
  )
}
