import { useState, useEffect, type KeyboardEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { api } from '../lib/api'
import { useScope, withScope, type Scope } from '../lib/scope'
import { formatAmount } from '../lib/format'
import { catColor, hueFor, Amount, Empty, Eyebrow, Btn, Select } from '../components/ui'
import { BarChart, RankedBars, Legend } from '../components/charts'
import type { BarDatum, BarRef, RankedItem } from '../components/charts'
import type { StatisticsData, StatRange, StatForecast, StatCashflowPoint } from '../lib/types'
import VariableFlowsModal from '../components/VariableFlowsModal'
import CategoryFlowsModal from '../components/CategoryFlowsModal'
import CategoryMerchantsModal from '../components/CategoryMerchantsModal'
import NetWorthPanel from '../components/NetWorthPanel'
import ScenarioEditor from '../components/ScenarioEditor'
import { type ScenarioAdjustment, loadScenario, saveScenario, projectBalance } from '../lib/scenario'
import { PERIOD_KEYS, periodRange, formatMonth, readPeriod, type PeriodKey } from '../lib/period'

const TOP_CATEGORIES = 8
const UPCOMING_PREVIEW = 7
const PROJ_ROWS = [0, 3, 6, 12] as const // projection table rows: Heute + the horizons

// Net worth leads (the headline view) and is the default for users with no saved tab;
// a saved choice is respected (NW-D4).
const TABS = ['networth', 'trends', 'categories', 'forecast'] as const
type Tab = (typeof TABS)[number]
const readTab = (): Tab => {
  if (typeof localStorage === 'undefined') return 'networth'
  const saved = localStorage.getItem('stats-tab') ?? ''
  return (TABS as readonly string[]).includes(saved) ? (saved as Tab) : 'networth'
}

export default function StatisticsPage() {
  const { t, i18n } = useTranslation()
  const { scope } = useScope()
  const [period, setPeriod] = useState<PeriodKey>(readPeriod)
  const [showAllCats, setShowAllCats] = useState(false)
  // Two-level Ausgaben drill state, both owned HERE (the page owns `data`):
  //  • catDrill   — which category's Empfänger ranking is open (level-1, CategoryMerchantsModal)
  //  • payeeDrill — which payee inside that category is open (level-2 leaf, CategoryFlowsModal)
  const [catDrill, setCatDrill] = useState<RankedItem | null>(null)
  const [payeeDrill, setPayeeDrill] = useState<{ creditor: string | null; label: string } | null>(null)
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
    // Close BOTH drill levels — they captured the old window at click time; leaving either
    // open would show stale-window data against a list that has moved (review nit).
    setCatDrill(null)
    setPayeeDrill(null)
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
      {/* Period selector drives the Einnahmen/Ausgaben/Netto hero (shown on every tab). */}
      <Select value={period} onChange={e => changePeriod(e.target.value as PeriodKey)} ariaLabel={t('statistics.title')} className="w-[176px]">
        {PERIOD_KEYS.map(k => <option key={k} value={k}>{t(`statistics.period.${k}`)}</option>)}
      </Select>
    </div>
  )

  // One WAI-ARIA tablist, shared by the empty-period branch and the main render (so the
  // markup — and the aria-controls="stat-tabpanel" target — stays in a single place).
  const renderTabs = () => (
    <div className="stat-tabs" role="tablist" aria-label={t('statistics.title')} onKeyDown={onTabKey}>
      {TABS.map(k => (
        <button key={k} id={`stat-tab-${k}`} role="tab" aria-selected={tab === k} aria-controls="stat-tabpanel"
          tabIndex={tab === k ? 0 : -1} className={tab === k ? 'on' : ''} onClick={() => changeTab(k)}>
          {t(`statistics.tab.${k}`)}
        </button>
      ))}
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

  // ---- Hero: Einnahmen / Ausgaben / Netto (+ Ø/Mt + Sparquote%) ----
  const income = parseFloat(kpis.income)
  const expenses = parseFloat(kpis.expenses) // already signed (≤ 0)
  const net = income + expenses
  const rate = kpis.savings_rate
  const months = range.months
  const perMonth = (total: number) =>
    months > 1 ? t('statistics.summary.per_month', { value: formatAmount(Math.abs(total) / months) }) : null

  // The hero is the page-level banner: it appears on EVERY tab (net worth included) and
  // even for an empty period — then it honestly reads 0 / 0 / 0. Built once, rendered below.
  // The "ist dieser Monat normal?" comparison lives in the Verlauf chart (the Ø reference +
  // last-completed-month ▲/▼%), NOT here — the hero stays clean (figure + Ø/Mt. + Sparquote).
  const heroPanel = (
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
  )

  // The net-worth tab is window-independent (it reconstructs from transactions, not the
  // period), so it stays reachable even when the chosen period has no activity.
  if (data.transaction_count === 0 && tab !== 'networth') {
    return (
      <div className="page">{head}
        {range.clamped && <ClampHint range={range} locale={locale} t={t} />}
        {heroPanel}
        {renderTabs()}
        <div className="panel" id="stat-tabpanel" role="tabpanel" aria-labelledby={`stat-tab-${tab}`}>
          <Empty icon="statistics" title={t('statistics.empty_title')} body={t('statistics.no_data_period')} />
        </div>
      </div>
    )
  }

  // ---- chart data ----
  // Verlauf Ø-reference (§3.3b/VR1): "ist dieser Monat normal?" answered ON the cashflow chart.
  // "Completed" keys off the backend's Berlin-correct vs_average.last_complete_month — NOT a UTC
  // new Date() (review n1): a UTC YYYY-MM and the backend's Date.current Berlin YYYY-MM can
  // disagree for a few hours at a month boundary, which would split the Ø set from the partial
  // bar. Keying both off last_complete_month makes the averaged set match va.baseline_months.
  const va = data.vs_average
  const lastDone = va.last_complete_month
  const completedMonths = lastDone ? data.cashflow.filter(p => p.month <= lastDone) : []
  const meanOf = (sel: (p: StatCashflowPoint) => number) =>
    completedMonths.length ? completedMonths.reduce((s, p) => s + sel(p), 0) / completedMonths.length : null
  const incomeRef = meanOf(p => parseFloat(p.income))               // ≥ 0
  const expenseRef = meanOf(p => Math.abs(parseFloat(p.expenses)))  // magnitude, to match the ink bar
  const cashflowRefs: BarRef[] = []
  if (incomeRef != null && incomeRef > 0) cashflowRefs.push({ value: incomeRef, color: 'var(--income)', label: t('statistics.trend.typical_income') })
  if (expenseRef != null && expenseRef > 0) cashflowRefs.push({ value: expenseRef, color: 'var(--ink)', label: t('statistics.trend.typical_expenses') })

  // Compact "vs Ø" string for a completed month's hover tooltip: arrow + signed € + %. The
  // comparison lives on hover now (no permanent strip) — the dashed Ø line shows the gap at a
  // glance; hovering a bar reveals the exact number. null when there's no Ø to compare against.
  const vsTypical = (cur: number, ref: number | null): string | null => {
    if (ref == null || ref === 0) return null
    const d = cur - ref
    return `${d >= 0 ? '▲ +' : '▼ −'} ${formatAmount(Math.abs(d))} · ${nf1.format(Math.abs((d / Math.abs(ref)) * 100))} %`
  }
  const hasTypical = completedMonths.length >= 2 // only meaningful with ≥ 2 completed months to average

  const cashflowData: BarDatum[] = data.cashflow.map(p => {
    const inc = parseFloat(p.income); const exp = parseFloat(p.expenses); const n = parseFloat(p.net)
    // The current (in-progress) month is any bar past last_complete_month (or all of them when
    // there is no completed month) — keyed off the backend value, not a UTC nowKey (n1).
    const partial = !lastDone || p.month > lastDone
    const rows: [string, string][] = [
      [t('statistics.legend.income'), formatAmount(inc)],
      [t('statistics.legend.expenses'), formatAmount(exp)],
      [t('statistics.legend.net'), formatAmount(n)],
    ]
    // A COMPLETED month also carries its "vs Ø" comparison (income + spending magnitude).
    if (!partial && hasTypical) {
      const vi = vsTypical(inc, incomeRef)
      const ve = vsTypical(Math.abs(exp), expenseRef)
      if (vi) rows.push([t('statistics.trend.vs_income'), vi])
      if (ve) rows.push([t('statistics.trend.vs_expenses'), ve])
    }
    return {
      label: formatMonth(p.month, locale),
      partial,
      segments: [
        { key: 'in', value: inc, color: 'var(--income)' },
        { key: 'out', value: Math.abs(exp), color: 'var(--ink)', opacity: 0.5 },
      ],
      tooltip: <Tip title={formatMonth(p.month, locale)} rows={rows} />,
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

  // Ausgaben drill level-1: recover the source StatCategoryItem (its real id + uncat flag)
  // from the clicked RankedItem via the SAME id rule the page builds the bars with
  // (id === c.id ?? c.name ?? 'uncat'), then open CategoryMerchantsModal over the CLAMPED
  // window (data.range — invariants CM1/CM2), not the raw periodRange.
  const drillSrc = catDrill && data.categories.items.find(c => (c.id ?? c.name ?? 'uncat') === catDrill.id)

  return (
    <div className="page">
      {head}
      {range.clamped && <ClampHint range={range} locale={locale} t={t} />}

      {/* Hero — was rein / raus / übrig (cashflow summary). On EVERY tab (net worth too). */}
      {heroPanel}

      {/* Tabs — named by the question you're asking; keep everything to one screen */}
      {renderTabs()}

      <div className="stat-tab-panel" key={tab} id="stat-tabpanel" role="tabpanel" aria-labelledby={`stat-tab-${tab}`} tabIndex={0}>
        {tab === 'networth' && (
          <NetWorthPanel scope={scope} locale={locale} t={t} />
        )}
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
              <div className="panel-pad">
                <BarChart data={cashflowData} mode="grouped" refs={cashflowRefs} />
                {/* The "is this month normal?" comparison is now AMBIENT: the dashed Ø reference
                    lines show each bar's gap to the typical month at a glance, and a completed
                    bar's exact "vs Ø" delta is in its hover tooltip (see cashflowData). No strip. */}
              </div>
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
            <div className="panel-head">
              <h2 className="section-title">{t('statistics.chart.by_category')}</h2>
            </div>
            <div className="panel-pad">
              <RankedBars items={visibleCats} maxValue={catMax} formatValue={v => formatAmount(Math.abs(v))} onRowClick={setCatDrill} />
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

      {/* Ausgaben drill level-1: the clicked category's top Empfänger (CategoryMerchantsModal).
          A payee click escalates to the leaf (payeeDrill). The key (id / scope / clamped
          window) forces remount+refetch on any change; closing it clears BOTH levels. */}
      {drillSrc && (
        <CategoryMerchantsModal
          key={`m-${drillSrc.id ?? 'uncat'}-${scope}-${range.from}-${range.to}`}
          categoryId={drillSrc.id}
          uncategorized={drillSrc.id == null}
          categoryName={drillSrc.name}
          from={range.from} to={range.to}
          scope={scope} locale={locale} t={t}
          onPayee={setPayeeDrill}
          onClose={() => { setCatDrill(null); setPayeeDrill(null) }}
        />
      )}

      {/* Ausgaben drill level-2 leaf: one Empfänger's transactions inside that category
          (CategoryFlowsModal with `creditor`), rendered OVER the level-1 modal. Closing the
          leaf returns to the Empfänger list. The null bucket round-trips creditor="". */}
      {drillSrc && payeeDrill && (
        <CategoryFlowsModal
          key={`l-${drillSrc.id ?? 'uncat'}-${payeeDrill.creditor ?? '__null__'}-${scope}-${range.from}-${range.to}`}
          categoryId={drillSrc.id}
          uncategorized={drillSrc.id == null}
          categoryName={drillSrc.name}
          creditor={payeeDrill.creditor} payeeLabel={payeeDrill.label}
          from={range.from} to={range.to}
          scope={scope} locale={locale} t={t}
          onClose={() => setPayeeDrill(null)}
        />
      )}
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
