import { useState, useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { api } from '../lib/api'
import { useScope, withScope } from '../lib/scope'
import { formatAmount } from '../lib/format'
import { catColor, hueFor, Amount, Empty, Eyebrow, Btn, Select } from '../components/ui'
import { BarChart, RankedBars, Legend } from '../components/charts'
import type { BarDatum, RankedItem } from '../components/charts'
import type { StatisticsData, StatRange, StatForecast } from '../lib/types'
import { PERIOD_KEYS, periodRange, formatMonth, readPeriod, type PeriodKey } from '../lib/period'

const TOP_CATEGORIES = 8
const HORIZONS = [3, 6, 12] as const
type Horizon = (typeof HORIZONS)[number]

export default function StatisticsPage() {
  const { t, i18n } = useTranslation()
  const { scope } = useScope()
  const [period, setPeriod] = useState<PeriodKey>(readPeriod)
  const [showAllCats, setShowAllCats] = useState(false)
  const [horizon, setHorizon] = useState<Horizon>(3)
  const [data, setData] = useState<StatisticsData | null>(null)
  const [isLoading, setIsLoading] = useState(true)
  const [error, setError] = useState(false)

  const locale = i18n.language === 'de' ? 'de-DE' : 'en-GB'

  const fetchStats = async () => {
    setIsLoading(true)
    setError(false)
    try {
      const { from, to } = periodRange(period)
      const params = withScope(new URLSearchParams({ from, to }), scope)
      const res = await api(`/api/v1/statistics?${params.toString()}`)
      if (res.ok) setData(await res.json())
      else setError(true)
    } catch {
      setError(true)
    } finally {
      setIsLoading(false)
    }
  }

  useEffect(() => { fetchStats() }, [scope, period]) // eslint-disable-line react-hooks/exhaustive-deps

  const changePeriod = (k: PeriodKey) => {
    setPeriod(k)
    setShowAllCats(false)
    localStorage.setItem('stats-period', k)
  }

  const head = (
    <div className="page-head">
      <div>
        <div className="text-ink-muted text-[13px]">{t('statistics.subtitle')}</div>
        <h1 className="page-title mt-0.5">{t('statistics.title')}</h1>
      </div>
      <Select value={period} onChange={e => changePeriod(e.target.value as PeriodKey)} ariaLabel={t('statistics.title')} className="w-[176px]">
        {PERIOD_KEYS.map(k => <option key={k} value={k}>{t(`statistics.period.${k}`)}</option>)}
      </Select>
    </div>
  )

  if (isLoading) {
    return <div className="page">{head}<div className="text-ink-muted text-[13.5px]">{t('common.loading')}</div></div>
  }

  if (error || !data) {
    return (
      <div className="page">{head}
        <div className="panel panel-pad flex items-center justify-between gap-3">
          <span className="text-danger text-[13.5px]">{t('common.load_error')}</span>
          <Btn variant="secondary" size="sm" icon="sync" onClick={fetchStats}>{t('common.retry')}</Btn>
        </div>
      </div>
    )
  }

  const { kpis, range } = data
  const nf1 = new Intl.NumberFormat(locale, { maximumFractionDigits: 1 })
  const fmtAbs = (v: string) => formatAmount(Math.abs(parseFloat(v)))

  if (data.transaction_count === 0) {
    return (
      <div className="page">{head}
        {range.clamped && <ClampHint range={range} locale={locale} t={t} />}
        <div className="panel"><Empty icon="statistics" title={t('statistics.empty_title')} body={t('statistics.no_data_period')} /></div>
      </div>
    )
  }

  // ---- Hero: Einnahmen / Ausgaben / Netto (+ Ø/Mt + Sparquote%) ----
  const income = parseFloat(kpis.income)
  const expenses = parseFloat(kpis.expenses) // already signed (≤ 0)
  const net = income + expenses
  const rate = kpis.savings_rate
  const months = range.months
  const perMonth = (total: number) =>
    months > 1 ? t('statistics.summary.per_month', { value: formatAmount(Math.abs(total) / months) }) : null

  // ---- chart data ----
  const cashflowData: BarDatum[] = data.cashflow.map(p => {
    const inc = parseFloat(p.income); const exp = parseFloat(p.expenses); const n = parseFloat(p.net)
    return {
      label: formatMonth(p.month, locale),
      segments: [
        { key: 'in', value: inc, color: 'var(--income)' },
        { key: 'out', value: Math.abs(exp), color: 'var(--ink)', opacity: 0.5 },
      ],
      tooltip: <Tip title={formatMonth(p.month, locale)} rows={[
        [t('statistics.legend.income'), formatAmount(inc)],
        [t('statistics.legend.expenses'), formatAmount(exp)],
        [t('statistics.legend.net'), formatAmount(n)],
      ]} />,
    }
  })

  const fvData: BarDatum[] = data.fixed_variable.map(p => {
    const fixed = parseFloat(p.fixed); const variable = parseFloat(p.variable)
    return {
      label: formatMonth(p.month, locale),
      segments: [
        { key: 'fixed', value: Math.abs(fixed), color: 'var(--brass)' },
        { key: 'variable', value: Math.abs(variable), color: 'var(--ink)', opacity: 0.32 },
      ],
      tooltip: <Tip title={formatMonth(p.month, locale)} rows={[
        [t('statistics.legend.fixed'), formatAmount(fixed)],
        [t('statistics.legend.variable'), formatAmount(variable)],
      ]} />,
    }
  })

  // ---- one ranked category list (no muted group) ----
  const catItems: RankedItem[] = data.categories.items.map(c => ({
    id: c.id ?? c.name ?? 'uncat',
    label: c.name || t('statistics.cat.uncategorized'),
    value: parseFloat(c.amount),
    share: c.share,
    color: catColor(hueFor(c.name || 'uncat')),
  }))
  const catMax = Math.max(1, ...catItems.map(c => Math.abs(c.value)))
  const visibleCats = showAllCats ? catItems : catItems.slice(0, TOP_CATEGORIES)
  const hiddenCount = catItems.length - visibleCats.length

  return (
    <div className="page">
      {head}
      {range.clamped && <ClampHint range={range} locale={locale} t={t} />}

      {/* Hero — was rein / raus / übrig */}
      <div className="panel stat-hero">
        <div className="stat-hero-col">
          <Eyebrow>{t('statistics.summary.income')}</Eyebrow>
          <div className="stat-hero-fig"><Amount value={kpis.income} /></div>
          {perMonth(income) && <div className="stat-hero-sub">{perMonth(income)}</div>}
        </div>
        <div className="stat-hero-col">
          <Eyebrow>{t('statistics.summary.expenses')}</Eyebrow>
          <div className="stat-hero-fig"><Amount value={kpis.expenses} /></div>
          {perMonth(expenses) && <div className="stat-hero-sub">{perMonth(expenses)}</div>}
        </div>
        <div className="stat-hero-col">
          <Eyebrow>{t('statistics.summary.net')}</Eyebrow>
          <div className="stat-hero-fig"><Amount value={net} /></div>
          {perMonth(net) && <div className="stat-hero-sub">{perMonth(net)}</div>}
          {rate != null && <div className="stat-hero-rate">{t('statistics.summary.savings_rate', { value: nf1.format(rate) })}</div>}
        </div>
      </div>

      {/* KPI strip */}
      <div className="panel stat-kpis mb-5">
        <div className="stat-kpi">
          <Eyebrow>{t('statistics.kpi.fixed_costs_so_far')}</Eyebrow>
          <div className="stat-kpi-val"><span className="amt amt-neg">{fmtAbs(kpis.fixed_monthly)}</span></div>
          <div className="stat-kpi-sub">{t('statistics.kpi.recurring_count', { n: kpis.recurring_payment_count })}</div>
        </div>

        <div className="stat-kpi">
          <Eyebrow>{t('statistics.kpi.top_category')}</Eyebrow>
          {kpis.top_category ? (
            <>
              <div className="stat-kpi-val"><span className="amt amt-neg">{fmtAbs(kpis.top_category.amount)}</span></div>
              <div className="stat-kpi-sub">{kpis.top_category.name || t('statistics.cat.uncategorized')}</div>
            </>
          ) : <div className="stat-kpi-val"><span>—</span></div>}
        </div>
      </div>

      {/* Cashflow + category breakdown */}
      <div className="stat-grid">
        <div className="panel">
          <div className="panel-head">
            <h2 className="section-title">{t('statistics.chart.cashflow')}</h2>
            <Legend items={[
              { label: t('statistics.legend.income'), color: 'var(--income)' },
              { label: t('statistics.legend.expenses'), color: 'var(--ink)', opacity: 0.5 },
            ]} />
          </div>
          <div className="panel-pad"><BarChart data={cashflowData} mode="grouped" /></div>
        </div>

        <div className="panel">
          <div className="panel-head"><h2 className="section-title">{t('statistics.chart.by_category')}</h2></div>
          <div className="panel-pad">
            <RankedBars items={visibleCats} maxValue={catMax} formatValue={v => formatAmount(Math.abs(v))} />
            {hiddenCount > 0 && (
              <Btn variant="ghost" size="sm" className="mt-2" onClick={() => setShowAllCats(true)}>
                {t('statistics.cat.more', { n: hiddenCount })}
              </Btn>
            )}
            <div className="stat-foot">
              <span className="text-ink-muted text-[12.5px]">{t('statistics.legend.expenses')}</span>
              <span className="amt amt-neg mono text-[14px]">{fmtAbs(data.categories.total)}</span>
            </div>
          </div>
        </div>
      </div>

      {/* Fixed vs. variable */}
      <div className="panel mb-5">
        <div className="panel-head">
          <h2 className="section-title">{t('statistics.chart.fixed_vs_variable')}</h2>
          <Legend items={[
            { label: t('statistics.legend.fixed'), color: 'var(--brass)' },
            { label: t('statistics.legend.variable'), color: 'var(--ink)', opacity: 0.32 },
          ]} />
        </div>
        <div className="panel-pad"><BarChart data={fvData} mode="stacked" /></div>
      </div>

      {/* Forecast — Vorschau „nächste Monate" */}
      <ForecastPanel forecast={data.forecast} horizon={horizon} setHorizon={setHorizon} locale={locale} t={t} />
    </div>
  )
}

function ForecastPanel({ forecast, horizon, setHorizon, locale, t }: {
  forecast: StatForecast
  horizon: Horizon
  setHorizon: (h: Horizon) => void
  locale: string
  t: (k: string, o?: Record<string, unknown>) => string
}) {
  // Run-rate recurring (both directions) + symmetric average of the variable one-offs.
  const recIncome = parseFloat(forecast.recurring_income)        // ≥ 0
  const recExpenses = parseFloat(forecast.recurring_expenses)    // ≤ 0 (incl. Sparen — cashflow)
  const varIncome = parseFloat(forecast.variable_income)         // ≥ 0 (Ø non-recurring credits)
  const varExpenses = parseFloat(forecast.variable_expenses)     // ≤ 0 (Ø non-recurring debits)
  const recurringNet = recIncome + recExpenses
  const variableNet = varIncome + varExpenses
  const projectedNet = recurringNet + variableNet
  const balance = parseFloat(forecast.current_balance)
  const projectedBalance = balance + projectedNet * horizon
  const delta = projectedNet * horizon
  const months = forecast.avg_window_months
  const hasData = recIncome !== 0 || recExpenses !== 0 || varIncome !== 0 || varExpenses !== 0
  const upcoming = forecast.upcoming
  const signedDelta = (v: number) => (v >= 0 ? '+ ' : '− ') + formatAmount(Math.abs(v))

  return (
    <div className="panel">
      <div className="panel-head">
        <h2 className="section-title">
          {t('statistics.forecast.title')}
          <span className="text-ink-faint font-normal"> · {horizon === 12 ? t('statistics.forecast.trend') : `${horizon} ${t('statistics.forecast.horizon_unit')}`}</span>
        </h2>
        <div className="segmented" role="group" aria-label={t('statistics.forecast.title')}>
          {HORIZONS.map(h => (
            <button key={h} className={h === horizon ? 'on' : ''} onClick={() => setHorizon(h)} aria-pressed={h === horizon}>
              {h}
            </button>
          ))}
        </div>
      </div>
      <div className="panel-pad">
        {!hasData ? (
          <div className="fc-empty">{t('statistics.forecast.empty_series')}</div>
        ) : (
          <>
            <Eyebrow className="mb-2.5">{t('statistics.forecast.typical_month')}</Eyebrow>
            <div className="fc-typical">
              <span className="fc-flow">{t('statistics.forecast.recurring_net', { value: signedDelta(recurringNet) })}</span>
              <span className="fc-flow">{t('statistics.forecast.variable_net', { value: signedDelta(variableNet), n: months })}</span>
            </div>
            <div className="fc-net">
              <span className={'fc-net-fig amt ' + (projectedNet >= 0 ? 'amt-pos' : 'amt-neg')}>
                {t('statistics.forecast.projected_net', { value: signedDelta(projectedNet) })}
              </span>
            </div>
            <div className="fc-proj">
              <span>{t('statistics.forecast.projected_balance', { months: horizon })}</span>
              <span className="fc-proj-fig">{formatAmount(projectedBalance)}</span>
              <span className="fc-proj-delta">({signedDelta(delta)})</span>
            </div>

            {upcoming.length > 0 && (
              <div className="fc-list">
                <div className="fc-list-head">
                  <Eyebrow>{t('statistics.forecast.upcoming')}</Eyebrow>
                  <Amount value={forecast.upcoming_total} className="text-[13.5px]" />
                </div>
                {upcoming.map((it, i) => (
                  <div className="fc-row" key={it.name + it.date + i}>
                    <span className="fc-row-date">{formatDay(it.date, locale)}</span>
                    <span className="fc-row-name">
                      <span className={'fc-row-flow ' + it.direction} aria-hidden="true">{it.direction === 'inflow' ? '↓' : '↑'}</span>
                      <span>{it.name}</span>
                    </span>
                    <Amount value={it.amount} className="fc-row-amt" />
                  </div>
                ))}
              </div>
            )}
          </>
        )}
      </div>
    </div>
  )
}

// "YYYY-MM-DD" → short day label (e.g. "01.07." / "Jul 1") without a year.
function formatDay(dateStr: string, locale: string): string {
  const [y, m, d] = dateStr.split('-').map(Number)
  return new Intl.DateTimeFormat(locale, { day: '2-digit', month: '2-digit' }).format(new Date(y, m - 1, d))
}

function Tip({ title, rows }: { title: string; rows: [string, string][] }) {
  return (
    <>
      <div className="stat-tip-title">{title}</div>
      {rows.map(([label, val]) => (
        <div className="stat-tip-row" key={label}><span>{label}</span><span className="stat-tip-val">{val}</span></div>
      ))}
    </>
  )
}

function ClampHint({ range, locale, t }: { range: StatRange; locale: string; t: (k: string, o?: Record<string, unknown>) => string }) {
  return (
    <div className="text-ink-faint text-[12px] mono mb-4 -mt-2">
      {t('statistics.data_from', { month: formatMonth(range.from.slice(0, 7), locale) })}
    </div>
  )
}
