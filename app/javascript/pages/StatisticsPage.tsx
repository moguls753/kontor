import { useState, useEffect, type KeyboardEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { api } from '../lib/api'
import { useScope, withScope, type Scope } from '../lib/scope'
import { formatAmount } from '../lib/format'
import { catColor, hueFor, Amount, DeltaTag, Empty, Eyebrow, Btn, Select } from '../components/ui'
import { BarChart, RankedBars, Legend } from '../components/charts'
import type { BarDatum, RankedItem } from '../components/charts'
import type { StatisticsData, StatRange, StatForecast, StatMerchants, StatDeltaPair } from '../lib/types'
import VariableFlowsModal from '../components/VariableFlowsModal'
import CategoryFlowsModal from '../components/CategoryFlowsModal'
import NetWorthPanel from '../components/NetWorthPanel'
import ScenarioEditor from '../components/ScenarioEditor'
import { type ScenarioAdjustment, loadScenario, saveScenario, projectBalance } from '../lib/scenario'
import { PERIOD_KEYS, periodRange, formatMonth, readPeriod, type PeriodKey } from '../lib/period'

const TOP_CATEGORIES = 8
const UPCOMING_PREVIEW = 7

// A merchant ranked-bar row. `id` is ONLY a React key; the genuine null-bucket flag is the
// explicit `merchantName` (null ⇒ the drill sends name="") — never overload the label string
// as the drill key, or a creditor literally named "unnamed" would be misrouted (review m1).
type MerchRow = RankedItem & { merchantName: string | null }
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
  const [catDrill, setCatDrill] = useState<RankedItem | null>(null)
  // Kategorie ↔ Empfänger toggle (does NOT persist — always resets to 'category' on reload).
  const [catView, setCatView] = useState<'category' | 'merchant'>('category')
  const [showAllMerchants, setShowAllMerchants] = useState(false)
  const [merchants, setMerchants] = useState<StatMerchants | null>(null)
  const [merchantsStatus, setMerchantsStatus] = useState<'loading' | 'ready' | 'error'>('loading')
  // Merchant drill state lives HERE in the main page (owns data + catView), not in
  // ForecastPanel; carries the merchant + the CLAMPED window the list used (review B1/m6).
  const [drillMerchant, setDrillMerchant] = useState<{ name: string; label: string; from: string; to: string } | null>(null)
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

  // Lazily fetch the top-merchants list only while the Empfänger toggle is active, over the
  // CLAMPED window data.range (NOT raw periodRange — review m3/B1): the category bars + the
  // category drill key off data.range (CI1), so the merchant list must share that one window
  // or its figures silently diverge from the rest of the tab (and the drill, B1, mismatches
  // the row). Refetch on [scope, range.from, range.to, catView] (clamped-window deps).
  const rangeFrom = data?.range.from
  const rangeTo = data?.range.to
  useEffect(() => {
    if (catView !== 'merchant' || !rangeFrom || !rangeTo) return
    let alive = true
    setMerchantsStatus('loading')
    const params = withScope(new URLSearchParams({ from: rangeFrom, to: rangeTo }), scope)
    api(`/api/v1/statistics/merchants?${params.toString()}`)
      .then(async res => {
        if (!res.ok) { if (alive) setMerchantsStatus('error'); return }
        const json = await res.json()
        if (!alive) return
        setMerchants(json)
        setMerchantsStatus('ready')
      })
      .catch(() => { if (alive) setMerchantsStatus('error') })
    return () => { alive = false }
  }, [scope, rangeFrom, rangeTo, catView])

  const changePeriod = (k: PeriodKey) => {
    setPeriod(k)
    setShowAllCats(false)
    setShowAllMerchants(false)
    // Close any open drill — it captured the old window at click time; leaving it open
    // would show stale-window data against a list that has moved (review nit).
    setCatDrill(null)
    setDrillMerchant(null)
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

  // "Dieser Monat vs. dein Schnitt": the selected window's per-month rate vs. the trailing
  // forecast window (rides on #show — no second fetch). Hide the chip when there's no
  // trailing history (baseline_months 0); the backend self-adjusts the divisor otherwise.
  const va = data.vs_average
  const showVs = va.baseline_months > 0
  // Partial-month honesty (§3.4, review m2): the baseline ALWAYS excludes the current partial
  // month, but the current-side divisor (month_span) counts a partial trailing month as whole.
  // So whenever range.to is NOT a month-end the divisors are asymmetric → append "anteilig"/
  // "so far". Broader than just this_month: mid-month, m3/m6/m12/ytd all end on a partial day.
  const toDate = new Date(range.to + 'T00:00:00')
  const partial = toDate.getDate() !== new Date(toDate.getFullYear(), toDate.getMonth() + 1, 0).getDate()
  const vsBaseLabel = t(partial ? 'statistics.vs.baseline_partial' : 'statistics.vs.baseline', { n: va.baseline_months })
  // Sign→colour per metric (review B2 — verified, NOT the intuitive mapping): expenses are
  // signed-negative, so spending MORE is delta < 0 and must read RED → good='up' (which makes
  // delta < 0 → red). income up→green, net up→green, expenses up(delta<0)→red.
  const vsLine = (pair: StatDeltaPair, ariaKey: string) => showVs && (
    <div className="stat-hero-vs">
      <DeltaTag delta={parseFloat(pair.delta)} pct={pair.pct} good="up"
        formatValue={v => formatAmount(v)} locale={locale} ariaLabel={t(ariaKey)} />
      <span className="stat-hero-vs-base">{vsBaseLabel}</span>
    </div>
  )

  // The hero is the page-level banner: it appears on EVERY tab (net worth included) and
  // even for an empty period — then it honestly reads 0 / 0 / 0. Built once, rendered below.
  const heroPanel = (
    <div className="panel stat-hero">
      <div className="stat-hero-col">
        <Eyebrow>{t('statistics.summary.income')}</Eyebrow>
        <div className="stat-hero-fig"><Amount value={kpis.income} /></div>
        {perMonth(income) && <div className="stat-hero-sub">{perMonth(income)}</div>}
        {vsLine(va.income, 'statistics.vs.aria_income')}
      </div>
      <div className="stat-hero-col">
        <Eyebrow>{t('statistics.summary.expenses')}</Eyebrow>
        <div className="stat-hero-fig"><Amount value={kpis.expenses} /></div>
        {perMonth(expenses) && <div className="stat-hero-sub">{perMonth(expenses)}</div>}
        {vsLine(va.expenses, 'statistics.vs.aria_expenses')}
      </div>
      <div className="stat-hero-col">
        <Eyebrow>{t('statistics.summary.net')}</Eyebrow>
        <div className="stat-hero-fig"><Amount value={net} /></div>
        {perMonth(net) && <div className="stat-hero-sub">{perMonth(net)}</div>}
        {rate != null && <div className="stat-hero-rate">{t('statistics.summary.savings_rate', { value: nf1.format(rate) })}</div>}
        {vsLine(va.net, 'statistics.vs.aria_net')}
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

  // Category drill-through: recover the source StatCategoryItem (its real id + uncat
  // flag) from the clicked RankedItem via the SAME id rule the page builds the bars with
  // (id === c.id ?? c.name ?? 'uncat'), then open CategoryFlowsModal over the CLAMPED
  // window (data.range — invariant CI1), not the raw periodRange.
  const drillSrc = catDrill && data.categories.items.find(c => (c.id ?? c.name ?? 'uncat') === catDrill.id)

  // ---- merchant ranked list (Empfänger toggle) ----
  // Map merchant items → RankedItem exactly as categories, but carry the genuine null bucket
  // as an explicit merchantName flag (null ⇒ name="" in the drill); the RankedItem.id is only
  // a unique React key, NEVER the drill payload (review m1).
  const merchantItems: MerchRow[] = (merchants?.items ?? []).map((m, i) => ({
    id: m.name ?? `__null__${i}`,
    merchantName: m.name,
    label: m.name || t('statistics.merchant.unnamed'),
    value: parseFloat(m.amount),
    share: m.share,
    color: catColor(hueFor(m.name || 'unnamed')),
  }))
  const merchMax = Math.max(1, ...merchantItems.map(m => Math.abs(m.value)))
  const visibleMerchants = showAllMerchants ? merchantItems : merchantItems.slice(0, TOP_CATEGORIES)
  const hiddenMerchants = merchantItems.length - visibleMerchants.length

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
            <div className="panel-head">
              <h2 className="section-title">{t('statistics.chart.by_category')}</h2>
              {/* Kategorie ↔ Empfänger segmented toggle (aria-pressed pair). */}
              <div className="stat-seg" role="group" aria-label={t('statistics.chart.by_category')}>
                <button type="button" className={catView === 'category' ? 'on' : ''} aria-pressed={catView === 'category'}
                  onClick={() => setCatView('category')}>{t('statistics.merchant.by_category')}</button>
                <button type="button" className={catView === 'merchant' ? 'on' : ''} aria-pressed={catView === 'merchant'}
                  onClick={() => setCatView('merchant')}>{t('statistics.merchant.by_merchant')}</button>
              </div>
            </div>
            <div className="panel-pad">
              {catView === 'category' ? (
                <>
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
                </>
              ) : merchantsStatus === 'loading' ? (
                <div className="vf-state">{t('common.loading')}</div>
              ) : merchantsStatus === 'error' ? (
                <div className="vf-state">{t('common.load_error')}</div>
              ) : (
                <>
                  <RankedBars items={visibleMerchants} maxValue={merchMax} formatValue={v => formatAmount(Math.abs(v))}
                    onRowClick={(it) => {
                      const m = it as MerchRow
                      setDrillMerchant({ name: m.merchantName ?? '', label: m.label, from: range.from, to: range.to })
                    }} />
                  {hiddenMerchants > 0 && (
                    <Btn variant="ghost" size="sm" className="mt-2" onClick={() => setShowAllMerchants(true)}>
                      {t('statistics.cat.more', { n: hiddenMerchants })}
                    </Btn>
                  )}
                  <div className="stat-foot">
                    <span className="text-ink-muted text-[12.5px]">{t('statistics.merchant.payee_total')}</span>
                    <span className="amt amt-neg mono text-[14px]">{fmtAbs(merchants?.total ?? '0')}</span>
                  </div>
                </>
              )}
            </div>
          </div>
        )}

        {tab === 'forecast' && (
          <ForecastPanel forecast={data.forecast} locale={locale} t={t} scope={scope} />
        )}
      </div>

      {drillSrc && (
        <CategoryFlowsModal
          key={`${drillSrc.id ?? 'uncat'}-${scope}-${range.from}-${range.to}`}
          categoryId={drillSrc.id}
          uncategorized={drillSrc.id == null}
          categoryName={drillSrc.name}
          from={range.from} to={range.to}
          scope={scope} locale={locale} t={t}
          onClose={() => setCatDrill(null)}
        />
      )}

      {/* Merchant drill — the SAME VariableFlowsModal in merchant mode (kind is ignored when
          `merchant` is set). The key remounts/refetches when window/scope/merchant change; the
          null-bucket drill round-trips name="". */}
      {drillMerchant && (
        <VariableFlowsModal
          key={`merchant-${drillMerchant.name}-${scope}-${range.from}-${range.to}`}
          kind="expenses"
          merchant={drillMerchant}
          scope={scope} locale={locale} t={t}
          onClose={() => setDrillMerchant(null)}
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
