import { useState, useEffect, type KeyboardEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { api } from '../lib/api'
import { useScope, withScope, type Scope } from '../lib/scope'
import { formatAmount } from '../lib/format'
import { catColor, hueFor, Amount, Empty, Eyebrow, Btn, Select } from '../components/ui'
import { BarChart, RankedBars, Legend } from '../components/charts'
import type { BarDatum, RankedItem } from '../components/charts'
import type { StatisticsData, StatRange, StatForecast } from '../lib/types'
import VariableFlowsModal from '../components/VariableFlowsModal'
import ScenarioEditor from '../components/ScenarioEditor'
import { type ScenarioAdjustment, loadScenario, saveScenario, projectBalance } from '../lib/scenario'
import { PERIOD_KEYS, periodRange, formatMonth, readPeriod, type PeriodKey } from '../lib/period'

const TOP_CATEGORIES = 8
const UPCOMING_PREVIEW = 7
const PROJ_ROWS = [0, 3, 6, 12] as const // projection table rows: Heute + the horizons

const TABS = ['trends', 'categories', 'forecast'] as const
type Tab = (typeof TABS)[number]
const readTab = (): Tab => {
  if (typeof localStorage === 'undefined') return 'trends'
  const saved = localStorage.getItem('stats-tab') ?? ''
  return (TABS as readonly string[]).includes(saved) ? (saved as Tab) : 'trends'
}

export default function StatisticsPage() {
  const { t, i18n } = useTranslation()
  const { scope } = useScope()
  const [period, setPeriod] = useState<PeriodKey>(readPeriod)
  const [showAllCats, setShowAllCats] = useState(false)
  const [tab, setTab] = useState<Tab>(readTab)
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

  const changeTab = (k: Tab) => {
    setTab(k)
    localStorage.setItem('stats-tab', k)
  }

  // Roving arrow-key navigation across the tablist (WAI-ARIA tabs, automatic activation).
  const onTabKey = (e: KeyboardEvent<HTMLDivElement>) => {
    const i = TABS.indexOf(tab)
    const next =
      e.key === 'ArrowRight' ? TABS[(i + 1) % TABS.length]
        : e.key === 'ArrowLeft' ? TABS[(i - 1 + TABS.length) % TABS.length]
          : e.key === 'Home' ? TABS[0]
            : e.key === 'End' ? TABS[TABS.length - 1]
              : null
    if (next) {
      e.preventDefault()
      changeTab(next)
      document.getElementById(`stat-tab-${next}`)?.focus()
    }
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

      {/* Tabs — named by the question you're asking; keep everything to one screen */}
      <div className="stat-tabs" role="tablist" aria-label={t('statistics.title')} onKeyDown={onTabKey}>
        {TABS.map(k => (
          <button key={k} id={`stat-tab-${k}`} role="tab" aria-selected={tab === k} aria-controls="stat-tabpanel"
            tabIndex={tab === k ? 0 : -1} className={tab === k ? 'on' : ''} onClick={() => changeTab(k)}>
            {t(`statistics.tab.${k}`)}
          </button>
        ))}
      </div>

      <div className="stat-tab-panel" key={tab} id="stat-tabpanel" role="tabpanel" aria-labelledby={`stat-tab-${tab}`} tabIndex={0}>
        {tab === 'trends' && (
          <div className="stat-grid stat-grid-even">
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
              <div className="panel-head">
                <h2 className="section-title">{t('statistics.chart.fixed_vs_variable')}</h2>
                <Legend items={[
                  { label: t('statistics.legend.fixed'), color: 'var(--brass)' },
                  { label: t('statistics.legend.variable'), color: 'var(--ink)', opacity: 0.32 },
                ]} />
              </div>
              <div className="panel-pad">
                <BarChart data={fvData} mode="stacked" />
                <div className="stat-context">
                  <span>{t('statistics.kpi.fixed_costs_so_far')}</span>
                  <span className="stat-context-fig">{fmtAbs(kpis.fixed_monthly)}</span>
                  <span>· {t('statistics.kpi.recurring_count', { n: kpis.recurring_payment_count })}</span>
                </div>
              </div>
            </div>
          </div>
        )}

        {tab === 'categories' && (
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
        )}

        {tab === 'forecast' && (
          <ForecastPanel forecast={data.forecast} locale={locale} t={t} scope={scope} />
        )}
      </div>
    </div>
  )
}

function ForecastPanel({ forecast, locale, t, scope }: {
  forecast: StatForecast
  locale: string
  t: (k: string, o?: Record<string, unknown>) => string
  scope: Scope
}) {
  const [showAllUpcoming, setShowAllUpcoming] = useState(false)
  const [drillKind, setDrillKind] = useState<'income' | 'expenses' | null>(null)
  // "Was-wäre-wenn" scenario: client-only assumptions (localStorage), layered on top of
  // the baseline via projectBalance. Survives a scope switch (the baseline re-fetches,
  // these stay and re-apply). Reset clears them.
  const [scenario, setScenario] = useState<ScenarioAdjustment[]>(() => loadScenario())
  useEffect(() => { saveScenario(scenario) }, [scenario])
  const scenarioActive = scenario.length > 0
  // Run-rate recurring (both directions) + symmetric average of the variable one-offs.
  const recIncome = parseFloat(forecast.recurring_income)        // ≥ 0
  const recExpenses = parseFloat(forecast.recurring_expenses)    // ≤ 0 (incl. Sparen — cashflow)
  const varIncome = parseFloat(forecast.variable_income)         // ≥ 0 (Ø non-recurring credits)
  const varExpenses = parseFloat(forecast.variable_expenses)     // ≤ 0 (Ø non-recurring debits)
  const recurringNet = recIncome + recExpenses
  const variableNet = varIncome + varExpenses
  const projectedNet = recurringNet + variableNet
  const balance = parseFloat(forecast.current_balance)
  // Two projection lenses: Liquide (spending accounts only — the runway that can go
  // underwater) and Gesamt (incl. investment — net worth). Same start today when no
  // recurring savings-transfer exists; the liquid rate diverges once a Sparplan recurs.
  const liquidBalance = parseFloat(forecast.liquid_balance)
  const liquidNet = parseFloat(forecast.liquid_net)
  const months = forecast.avg_window_months
  const hasData = recIncome !== 0 || recExpenses !== 0 || varIncome !== 0 || varExpenses !== 0
  const upcoming = forecast.upcoming
  const signedDelta = (v: number) => (v >= 0 ? '+ ' : '− ') + formatAmount(Math.abs(v))
  // Absolute saldo: no leading sign when positive, but a U+2212 (not the Intl hyphen) when
  // negative, so the whole receipt shares one minus glyph + spacing.
  const saldo = (v: number) => (v < 0 ? '− ' : '') + formatAmount(Math.abs(v))
  // Scenario-aware projection (≡ the linear baseline byte-for-byte when no assumptions).
  const liqAt = (h: number) => projectBalance(liquidBalance, liquidNet, scenario, h, 'liquid')
  const totAt = (h: number) => projectBalance(balance, projectedNet, scenario, h, 'total')
  // Scenario-adjusted "typical month": recurring BOTH-lens assumptions move the Kassenzettel
  // (a raise lifts Wiederkehrende Einnahmen, its net follows); one-offs + savings-lens don't
  // (not a typical month / net-worth-neutral). Degrades to the baseline with no assumptions.
  // Route a recurring both-lens delta by the line it belongs to (its source direction),
  // NOT the delta sign — so "Miete 800 → 520" (delta +280) LOWERS the expense line instead
  // of inflating income. Older persisted adjustments without a bucket fall back to the sign.
  const recBucket = (a: ScenarioAdjustment) => a.bucket ?? (a.amount >= 0 ? 'income' : 'expense')
  const scRecIncome = scenario.reduce((s, a) => s + (a.kind === 'recurring' && a.lens === 'both' && recBucket(a) === 'income' ? a.amount : 0), 0)
  const scRecExpense = scenario.reduce((s, a) => s + (a.kind === 'recurring' && a.lens === 'both' && recBucket(a) === 'expense' ? a.amount : 0), 0)
  const recIncomeScn = recIncome + scRecIncome
  const recExpensesScn = recExpenses + scRecExpense
  const projectedNetScn = recIncomeScn + recExpensesScn + variableNet
  const kassChanged = scRecIncome !== 0 || scRecExpense !== 0

  return (
    <div className="panel">
      <div className="panel-head">
        <h2 className="section-title">{t('statistics.forecast.heading')}</h2>
      </div>
      <div className="panel-pad">
        {!hasData ? (
          <div className="fc-empty">{t('statistics.forecast.empty_series')}</div>
        ) : (
          <>
            <Eyebrow className="mb-3">
              {t('statistics.forecast.typical_month')}
              {kassChanged && <span className="fc-ledger-scn"> · {t('statistics.forecast.scenario.with_scenario')}</span>}
            </Eyebrow>
            <div className="fc-ledger">
              <span className="fc-ledger-label">{t('statistics.forecast.recurring_income_label')}</span>
              <span className={'fc-ledger-amt' + (scRecIncome !== 0 ? ' is-scn' : '')}>{signedDelta(recIncomeScn)}</span>
              <span className="fc-ledger-label">{t('statistics.forecast.recurring_expenses_label')}</span>
              <span className={'fc-ledger-amt' + (scRecExpense !== 0 ? ' is-scn' : '')}>{signedDelta(recExpensesScn)}</span>
              <button type="button" className="fc-ledger-rowbtn" onClick={() => setDrillKind('income')} aria-haspopup="dialog">
                <span className="fc-ledger-label is-link">{t('statistics.forecast.variable_income_label', { n: months })}</span>
                <span className="fc-ledger-amt">{signedDelta(varIncome)}</span>
              </button>
              <button type="button" className="fc-ledger-rowbtn" onClick={() => setDrillKind('expenses')} aria-haspopup="dialog">
                <span className="fc-ledger-label is-link">{t('statistics.forecast.variable_expenses_label', { n: months })}</span>
                <span className="fc-ledger-amt">{signedDelta(varExpenses)}</span>
              </button>
              <div className="fc-ledger-rule" />
              <span className="fc-ledger-label is-sum">{t('statistics.forecast.net_label')}</span>
              <span className={'fc-ledger-amt is-sum amt ' + (projectedNetScn >= 0 ? 'amt-pos' : 'amt-neg')}>{signedDelta(projectedNetScn)}</span>
            </div>
            <table className="fc-proj">
              <caption className="sr-only">
                {t('statistics.forecast.heading')}{scenarioActive ? ' · ' + t('statistics.forecast.scenario.active', { n: scenario.length }) : ''}
              </caption>
              <thead>
                <tr>
                  <td className="fc-proj-corner" aria-hidden="true" />
                  <th scope="col" className="fc-proj-head is-liquid">
                    <span className="fc-proj-head-key">{t('statistics.forecast.proj_liquid')}</span>
                    <span className="fc-proj-head-sub">{t('statistics.forecast.proj_liquid_sub')}</span>
                  </th>
                  <th scope="col" className="fc-proj-head">
                    <span className="fc-proj-head-key">{t('statistics.forecast.proj_total')}</span>
                    <span className="fc-proj-head-sub">{t('statistics.forecast.proj_total_sub')}</span>
                  </th>
                </tr>
              </thead>
              <tbody>
                {PROJ_ROWS.map(h => {
                  const liq = liqAt(h)
                  const tot = totAt(h)
                  return (
                    <tr key={h}>
                      <th scope="row" className="fc-proj-time">
                        {h === 0 ? t('statistics.forecast.proj_now') : t('statistics.forecast.balance_future', { months: h })}
                      </th>
                      <td className={'fc-proj-amt is-liquid' + (liq < 0 ? ' neg' : '')}>
                        {saldo(liq)}{h > 0 && <span className="fc-proj-delta">({signedDelta(liq - liquidBalance)})</span>}
                      </td>
                      <td className={'fc-proj-amt' + (tot < 0 ? ' neg' : '')}>
                        {saldo(tot)}{h > 0 && <span className="fc-proj-delta">({signedDelta(tot - balance)})</span>}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
            {scenarioActive && (
              <p className="fc-proj-vs">
                <span className="fc-proj-vs-lead">{t('statistics.forecast.scenario.vs_baseline', { months: 12 })}</span>
                <span className="fc-proj-vs-item"><span className="fc-proj-vs-key">{t('statistics.forecast.proj_liquid')}</span>{signedDelta(liqAt(12) - (liquidBalance + liquidNet * 12))}</span>
                <span className="fc-proj-vs-item"><span className="fc-proj-vs-key">{t('statistics.forecast.proj_total')}</span>{signedDelta(totAt(12) - (balance + projectedNet * 12))}</span>
              </p>
            )}

            <ScenarioEditor
              adjustments={scenario}
              items={forecast.recurring_items}
              onAdd={a => setScenario(s => [...s, a])}
              onRemove={id => setScenario(s => s.filter(x => x.id !== id))}
              onReset={() => setScenario([])}
              locale={locale}
              t={t}
            />

            {upcoming.length > 0 && (
              <div className="fc-list">
                <div className="fc-list-head">
                  <Eyebrow>{t('statistics.forecast.upcoming')}</Eyebrow>
                  <Amount value={forecast.upcoming_total} className="text-[13.5px]" />
                </div>
                {(showAllUpcoming ? upcoming : upcoming.slice(0, UPCOMING_PREVIEW)).map((it, i) => (
                  <div className="fc-row" key={it.name + it.date + i}>
                    <span className="fc-row-date">{formatDay(it.date, locale)}</span>
                    <span className="fc-row-name">
                      <span className={'fc-row-flow ' + it.direction} aria-hidden="true">{it.direction === 'inflow' ? '↓' : '↑'}</span>
                      <span>{it.name}</span>
                    </span>
                    <Amount value={it.amount} className="fc-row-amt" />
                  </div>
                ))}
                {!showAllUpcoming && upcoming.length > UPCOMING_PREVIEW && (
                  <Btn variant="ghost" size="sm" className="mt-2" onClick={() => setShowAllUpcoming(true)}>
                    {t('statistics.cat.more', { n: upcoming.length - UPCOMING_PREVIEW })}
                  </Btn>
                )}
              </div>
            )}
          </>
        )}
      </div>
      {drillKind && (
        <VariableFlowsModal key={`${drillKind}-${scope}`} kind={drillKind} scope={scope} locale={locale} t={t} onClose={() => setDrillKind(null)} />
      )}
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
