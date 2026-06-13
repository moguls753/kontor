/* ============================================================================
   KONTOR — statistics chart primitives. Dependency-free, CSS-driven (hairline
   bars, tabular-mono figures, brass/ink/income tokens) so they flip for dark
   mode and stay on-brand. Presentation only: all data/state lives in the page.
   ============================================================================ */
import { useState, useRef, useEffect, useMemo, type CSSProperties, type ReactNode, type MouseEvent } from 'react'

export interface BarSegment { key: string; value: number; color: string; opacity?: number }
// `partial` marks an in-progress month (the current bar): the column renders hatched/lighter
// with a `now` marker under its axis label — so partialness is VISUAL, not a prose caveat.
export interface BarDatum { label: string; segments: BarSegment[]; tooltip?: ReactNode; partial?: boolean }
// A faint horizontal "Ø typical month" reference line drawn per series at `value` (same scale
// as the bars), with a small tick label. Inert/absent on charts that pass nothing.
export interface BarRef { value: number; color: string; label?: string }

/** Vertical bars — `grouped` (side-by-side, e.g. in/out) or `stacked` (e.g. fixed/variable).
 *  Optional per-series Ø `refs` (faint hairlines) + a per-datum `partial` flag (visibly
 *  partial current bar + a `nowLabel` marker) — both inert when absent (§3.3b). */
export function BarChart({ data, mode, height = 168, refs, nowLabel }: {
  data: BarDatum[]
  mode: 'grouped' | 'stacked'
  height?: number
  refs?: BarRef[]
  nowLabel?: string
}) {
  const max = Math.max(
    1,
    ...data.map(d =>
      mode === 'stacked'
        ? d.segments.reduce((sum, seg) => sum + Math.abs(seg.value), 0)
        : Math.max(0, ...d.segments.map(seg => Math.abs(seg.value)))
    ),
    // The Ø lines share the bars' scale — let a reference above every bar still fit on-chart.
    ...(refs ?? []).map(r => Math.abs(r.value)),
  )

  return (
    <div className="stat-chart">
      <div className="stat-bars" style={{ height }}>
        {data.map((d, i) => (
          <div className={'stat-col' + (d.partial ? ' is-partial' : '')} key={d.label + i}>
            {d.tooltip && <div className="stat-tip">{d.tooltip}</div>}
            <div className={'stat-stack' + (mode === 'grouped' ? ' grouped' : '')}>
              {d.segments
                .filter(seg => Math.abs(seg.value) > 0)
                .map(seg => (
                  <div
                    key={seg.key}
                    className="stat-bar"
                    style={{ height: `${(Math.abs(seg.value) / max) * 100}%`, background: seg.color, opacity: seg.opacity ?? 1, '--i': i } as CSSProperties}
                  />
                ))}
            </div>
          </div>
        ))}
        {(refs ?? []).filter(r => Math.abs(r.value) > 0).map((r, i) => (
          <div
            key={'ref' + i}
            className="stat-ref-line"
            style={{ bottom: `${(Math.abs(r.value) / max) * 100}%`, '--ref': r.color } as CSSProperties}
          >
            {r.label && <span className="stat-ref-tick">{r.label}</span>}
          </div>
        ))}
      </div>
      <div className="stat-axis">
        {data.map((d, i) => (
          <div key={d.label + i} className="stat-axis-label mono">
            {d.label}
            {d.partial && nowLabel && <span className="stat-now">{nowLabel}</span>}
          </div>
        ))}
      </div>
    </div>
  )
}

export interface RankedItem { id: string | number; label: string; value: number; share: number | null; color: string; muted?: boolean }

/** Horizontal ranked bars (category breakdown). `value` is signed; bars use magnitude.
 *  When `onRowClick` is given each row becomes a keyboard-accessible drill button
 *  (a11y: brass focus ring + hover tint via .stat-rank-row); otherwise it stays a
 *  non-interactive div (the prop is optional, so existing callers are unaffected). */
export function RankedBars({ items, maxValue, formatValue, onRowClick }: {
  items: RankedItem[]
  maxValue: number
  formatValue: (v: number) => string
  onRowClick?: (item: RankedItem) => void
}) {
  const max = Math.max(1, maxValue)
  return (
    <div className="stat-rank">
      {items.map((it, i) => {
        const inner = (
          <>
            <div className="stat-rank-main">
              <span className="stat-rank-label">{it.label}</span>
              <div className="stat-rank-track">
                <div className="stat-rank-fill" style={{ width: `${(Math.abs(it.value) / max) * 100}%`, background: it.color, '--i': i } as CSSProperties} />
              </div>
            </div>
            <div className="stat-rank-side">
              <span className="amt amt-neg mono stat-rank-amt">{formatValue(it.value)}</span>
              {it.share != null && <span className="stat-rank-share mono">{it.share}%</span>}
            </div>
          </>
        )
        const cls = 'stat-rank-row' + (it.muted ? ' muted' : '')
        return onRowClick
          ? <button type="button" className={cls + ' is-drill'} key={it.id} onClick={() => onRowClick(it)} aria-haspopup="dialog">{inner}</button>
          : <div className={cls} key={it.id}>{inner}</div>
      })}
    </div>
  )
}

export function Legend({ items }: { items: { label: string; color: string; opacity?: number }[] }) {
  return (
    <div className="stat-legend">
      {items.map(it => (
        <span key={it.label} className="stat-legend-item">
          <span className="stat-legend-dot" style={{ background: it.color, opacity: it.opacity ?? 1 }} />
          {it.label}
        </span>
      ))}
    </div>
  )
}

/* ----------------------------------------------------------------------------
   AreaSeries — dependency-free SVG line/area chart for the net-worth tab. Multi-
   series (e.g. Liquide + Gesamt), hairline-ruled with a ledger-green/brass/ink
   palette, tabular-mono axis labels and a hover guide + tooltip. Width is measured
   (ResizeObserver) so coordinates are crisp — no viewBox stroke distortion. Time-
   proportional x so uneven history renders honestly. All colours are CSS-var tokens
   passed by the caller, so it flips for dark mode.
   ---------------------------------------------------------------------------- */
const DAY_MS = 86_400_000
const dayNum = (iso: string) => {
  const [y, m, d] = iso.split('-').map(Number)
  return Math.floor(Date.UTC(y, m - 1, d) / DAY_MS)
}

export interface LinePoint { date: string; value: number }
export interface LineSeries { key: string; label: string; color: string; emphasis?: boolean; points: LinePoint[] }

// Round, human y-axis ticks (… 5k, 10k, 15k …) rather than evenly-split decimals.
function niceTicks(min: number, max: number, count = 4): number[] {
  if (!(max > min)) return [min]
  const raw = (max - min) / count
  const mag = 10 ** Math.floor(Math.log10(raw))
  const norm = raw / mag
  const step = (norm >= 5 ? 5 : norm >= 2 ? 2 : 1) * mag
  const ticks: number[] = []
  for (let v = Math.ceil(min / step) * step; v <= max + step * 1e-6; v += step) ticks.push(v)
  return ticks
}

export function AreaSeries({ series, locale, formatValue, formatAxis, height = 240 }: {
  series: LineSeries[]
  locale: string
  formatValue: (v: number) => string // full, for the hover tooltip
  formatAxis?: (v: number) => string // compact, for the y-axis gutter (defaults to formatValue)
  height?: number
}) {
  const fmtAxis = formatAxis ?? formatValue
  const ref = useRef<HTMLDivElement>(null)
  const [w, setW] = useState(0)
  const [hover, setHover] = useState<number | null>(null) // hovered day-number

  useEffect(() => {
    const el = ref.current
    if (!el) return
    const ro = new ResizeObserver(e => setW(Math.round(e[0].contentRect.width)))
    ro.observe(el)
    return () => ro.disconnect()
  }, [])

  const maps = useMemo(
    () => series.map(s => new Map(s.points.map(p => [dayNum(p.date), p]))),
    [series],
  )

  // Clear a stale hover guide when the series set changes (e.g. a keyboard lens/isolate
  // switch while the cursor rests on the plot) — it could otherwise paint at a now-
  // meaningless x, since .nw-svg is overflow:visible.
  useEffect(() => { setHover(null) }, [series])

  const geo = useMemo(() => {
    const pts = series.flatMap(s => s.points)
    if (!pts.length || w < 120) return null
    const PAD = { t: 14, r: 14, b: 26, l: 56 }
    const plotW = w - PAD.l - PAD.r
    const plotH = height - PAD.t - PAD.b
    const days = pts.map(p => dayNum(p.date))
    const minDay = Math.min(...days)
    const maxDay = Math.max(...days)
    const vals = pts.map(p => p.value)
    let yMin = Math.min(0, ...vals)
    let yMax = Math.max(0, ...vals)
    if (yMin === yMax) { yMax += 1; yMin -= 1 }
    const head = (yMax - yMin) * 0.08
    yMax += head
    if (yMin < 0) yMin -= head

    const x = (day: number) => (maxDay === minDay ? PAD.l + plotW / 2 : PAD.l + ((day - minDay) / (maxDay - minDay)) * plotW)
    const y = (v: number) => PAD.t + ((yMax - v) / (yMax - yMin)) * plotH
    const baseY = y(0)

    const lines = series.map(s => {
      const sp = s.points.map(p => ({ px: x(dayNum(p.date)), py: y(p.value) }))
      const line = sp.map((p, i) => `${i ? 'L' : 'M'}${p.px.toFixed(1)},${p.py.toFixed(1)}`).join(' ')
      const area = sp.length > 1
        ? `M${sp[0].px.toFixed(1)},${baseY.toFixed(1)} ${sp.map(p => `L${p.px.toFixed(1)},${p.py.toFixed(1)}`).join(' ')} L${sp[sp.length - 1].px.toFixed(1)},${baseY.toFixed(1)} Z`
        : '' // single-point series renders a circle instead (no degenerate zero-width area)
      return { key: s.key, color: s.color, emphasis: s.emphasis, single: sp.length === 1 ? sp[0] : null, line, area }
    })

    const yticks = niceTicks(yMin + head, yMax - head).map(v => ({ v, py: y(v) }))

    const union = Array.from(new Set(days)).sort((a, b) => a - b)
    const months: { day: number; label: string }[] = []
    let prev = ''
    for (const d of union) {
      const dt = new Date(d * DAY_MS)
      const mk = `${dt.getUTCFullYear()}-${dt.getUTCMonth()}`
      if (mk !== prev) {
        prev = mk
        const lbl = new Intl.DateTimeFormat(locale, { month: 'short', timeZone: 'UTC' }).format(dt)
        months.push({ day: d, label: dt.getUTCMonth() === 0 ? `${lbl} ${String(dt.getUTCFullYear()).slice(2)}` : lbl })
      }
    }
    const stepN = Math.max(1, Math.ceil(months.length / 7))
    const xticks = months.filter((_, i) => i % stepN === 0)

    return { PAD, plotW, plotH, minDay, maxDay, x, y, baseY, yMin, lines, yticks, xticks, union }
  }, [series, w, height, locale])

  if (!geo) return <div ref={ref} className="nw-chart" style={{ height }} />

  const onMove = (e: MouseEvent<SVGRectElement>) => {
    const r = e.currentTarget.getBoundingClientRect()
    const frac = Math.max(0, Math.min(1, (e.clientX - r.left) / r.width))
    const target = geo.minDay + frac * (geo.maxDay - geo.minDay)
    let nearest = geo.union[0]
    let best = Infinity
    for (const d of geo.union) {
      const dist = Math.abs(d - target)
      if (dist < best) { best = dist; nearest = d }
    }
    setHover(nearest)
  }

  const hoverX = hover != null ? geo.x(hover) : null
  const hoverItems = hover != null ? series.map((s, i) => ({ s, p: maps[i].get(hover) })).filter(o => o.p) : []
  const tipRight = hoverX != null && hoverX > w * 0.62

  return (
    <div ref={ref} className="nw-chart" style={{ height }}>
      <svg width={w} height={height} className="nw-svg" role="img" aria-label={series.map(s => s.label).join(', ')}>
        {geo.yticks.map(t => (
          <g key={t.v}>
            <line x1={geo.PAD.l} x2={w - geo.PAD.r} y1={t.py} y2={t.py} className="nw-grid" />
            <text x={geo.PAD.l - 9} y={t.py} className="nw-ylabel" textAnchor="end" dominantBaseline="middle">{fmtAxis(t.v)}</text>
          </g>
        ))}
        {geo.yMin < 0 && <line x1={geo.PAD.l} x2={w - geo.PAD.r} y1={geo.baseY} y2={geo.baseY} className="nw-baseline" />}

        {geo.lines.map(l => (
          <g key={l.key}>
            {l.area && <path d={l.area} className="nw-area" style={{ fill: l.color, opacity: l.emphasis ? 0.14 : 0.07 }} />}
            {l.single
              ? <circle cx={l.single.px} cy={l.single.py} r={4} style={{ fill: l.color }} />
              : <path d={l.line} pathLength={1} className={'nw-line' + (l.emphasis ? ' is-emph' : '')} style={{ stroke: l.color }} />}
          </g>
        ))}

        {geo.xticks.map(t => (
          <text key={t.day} x={geo.x(t.day)} y={height - 8} className="nw-xlabel" textAnchor="middle">{t.label}</text>
        ))}

        {hoverX != null && (
          <>
            <line x1={hoverX} x2={hoverX} y1={geo.PAD.t} y2={height - geo.PAD.b} className="nw-guide" />
            {hoverItems.map(({ s, p }) => <circle key={s.key} cx={hoverX} cy={geo.y(p!.value)} r={3.5} className="nw-dot" style={{ fill: s.color }} />)}
          </>
        )}

        <rect x={geo.PAD.l} y={geo.PAD.t} width={geo.plotW} height={geo.plotH} fill="transparent"
          onMouseMove={onMove} onMouseLeave={() => setHover(null)} />
      </svg>

      {hover != null && hoverItems.length > 0 && (
        <div className={'nw-tip' + (tipRight ? ' flip' : '')} style={{ left: hoverX! }}>
          <div className="nw-tip-title">
            {new Intl.DateTimeFormat(locale, { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' }).format(new Date(hover * DAY_MS))}
          </div>
          {hoverItems.map(({ s, p }) => (
            <div className="nw-tip-row" key={s.key}>
              <span className="nw-tip-dot" style={{ background: s.color }} />
              <span className="nw-tip-label">{s.label}</span>
              <span className="nw-tip-val">{formatValue(p!.value)}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
