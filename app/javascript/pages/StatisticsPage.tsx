import { useState, useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { api } from '../lib/api'
import { useScope, withScope } from '../lib/scope'
import { formatAmount } from '../lib/format'
import { catColor, hueFor, Empty, Eyebrow, Btn, Select } from '../components/ui'
import { BarChart, RankedBars, KpiMeter, DeltaTag, Legend } from '../components/charts'
import type { BarDatum, RankedItem } from '../components/charts'
import type { StatisticsData, StatRange } from '../lib/types'
import { PERIOD_KEYS, periodRange, formatMonth, readPeriod, type PeriodKey } from '../lib/period'

const TOP_CATEGORIES = 8

export default function StatisticsPage() {
  const { t, i18n } = useTranslation()
  const { scope } = useScope()
  const [period, setPeriod] = useState<PeriodKey>(readPeriod)
  const [showAllCats, setShowAllCats] = useState(false)
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

  // ---- KPI deltas vs. the prior equal-length window ----
  const rate = kpis.savings_rate
  const rateDelta = rate != null && kpis.savings_rate_prev != null ? rate - kpis.savings_rate_prev : null
  const curSpend = Math.abs(parseFloat(kpis.avg_monthly_expenses))
  const prevSpend = Math.abs(parseFloat(kpis.avg_monthly_expenses_prev))
  const spendDelta = prevSpend > 0 ? ((curSpend - prevSpend) / prevSpend) * 100 : null

  // ---- chart data ----
  const cashflowData: BarDatum[] = data.cashflow.map(p => {
    const inc = parseFloat(p.income); const exp = parseFloat(p.expenses); const net = parseFloat(p.net)
    return {
      label: formatMonth(p.month, locale),
      segments: [
        { key: 'in', value: inc, color: 'var(--income)' },
        { key: 'out', value: Math.abs(exp), color: 'var(--ink)', opacity: 0.5 },
      ],
      tooltip: <Tip title={formatMonth(p.month, locale)} rows={[
        [t('statistics.legend.income'), formatAmount(inc)],
        [t('statistics.legend.expenses'), formatAmount(exp)],
        [t('statistics.legend.net'), formatAmount(net)],
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

  const allCats = [...data.categories.spending, ...data.categories.transfers]
  const catMax = Math.max(1, ...allCats.map(c => Math.abs(parseFloat(c.amount))))
  const spendingItems: RankedItem[] = data.categories.spending.map(c => ({
    id: c.id ?? c.name ?? 'uncat',
    label: c.name || t('statistics.cat.uncategorized'),
    value: parseFloat(c.amount),
    share: c.share,
    color: catColor(hueFor(c.name || 'uncat')),
  }))
  const transferItems: RankedItem[] = data.categories.transfers.map(c => ({
    id: c.id ?? c.name ?? 'transfer',
    label: c.name || '—',
    value: parseFloat(c.amount),
    share: null,
    color: 'var(--ink-faint)',
    muted: true,
  }))
  const visibleSpending = showAllCats ? spendingItems : spendingItems.slice(0, TOP_CATEGORIES)
  const hiddenCount = spendingItems.length - visibleSpending.length

  return (
    <div className="page">
      {head}
      {range.clamped && <ClampHint range={range} locale={locale} t={t} />}

      {/* KPI strip */}
      <div className="panel stat-kpis mb-5">
        <div className="stat-kpi">
          <Eyebrow>{t('statistics.kpi.savings_rate')}</Eyebrow>
          <div className="stat-kpi-val">
            <span>{rate == null ? '—' : `${nf1.format(rate)} %`}</span>
            {rateDelta != null && <DeltaTag delta={rateDelta} goodWhenUp suffix=" pp" />}
          </div>
          {rate != null && <KpiMeter value={rate} />}
        </div>

        <div className="stat-kpi">
          <Eyebrow>{t('statistics.kpi.avg_monthly_expenses')}</Eyebrow>
          <div className="stat-kpi-val">
            <span className="amt amt-neg">{fmtAbs(kpis.avg_monthly_expenses)}</span>
            {spendDelta != null && <DeltaTag delta={spendDelta} goodWhenUp={false} suffix="%" />}
          </div>
          <div className="stat-kpi-sub">{t('statistics.kpi.vs_prev')}</div>
        </div>

        <div className="stat-kpi">
          <Eyebrow>{t('statistics.kpi.fixed_costs')}</Eyebrow>
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
            <RankedBars items={visibleSpending} maxValue={catMax} formatValue={v => formatAmount(Math.abs(v))} />
            {hiddenCount > 0 && (
              <Btn variant="ghost" size="sm" className="mt-2" onClick={() => setShowAllCats(true)}>
                {t('statistics.cat.more', { n: hiddenCount })}
              </Btn>
            )}
            {transferItems.length > 0 && (
              <>
                <div className="stat-group-label eyebrow">{t('statistics.cat.transfers_group')}</div>
                <RankedBars items={transferItems} maxValue={catMax} formatValue={v => formatAmount(Math.abs(v))} />
              </>
            )}
            <div className="stat-foot">
              <span className="text-ink-muted text-[12.5px]">{t('statistics.legend.expenses')}</span>
              <span className="amt amt-neg mono text-[14px]">{fmtAbs(kpis.expenses)}</span>
            </div>
          </div>
        </div>
      </div>

      {/* Fixed vs. variable */}
      <div className="panel">
        <div className="panel-head">
          <h2 className="section-title">{t('statistics.chart.fixed_vs_variable')}</h2>
          <Legend items={[
            { label: t('statistics.legend.fixed'), color: 'var(--brass)' },
            { label: t('statistics.legend.variable'), color: 'var(--ink)', opacity: 0.32 },
          ]} />
        </div>
        <div className="panel-pad"><BarChart data={fvData} mode="stacked" /></div>
      </div>
    </div>
  )
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
