/* ============================================================================
   KONTOR — statistics chart primitives. Dependency-free, CSS-driven (hairline
   bars, tabular-mono figures, brass/ink/income tokens) so they flip for dark
   mode and stay on-brand. Presentation only: all data/state lives in the page.
   ============================================================================ */
import type { CSSProperties, ReactNode } from 'react'

export interface BarSegment { key: string; value: number; color: string; opacity?: number }
export interface BarDatum { label: string; segments: BarSegment[]; tooltip?: ReactNode }

/** Vertical bars — `grouped` (side-by-side, e.g. in/out) or `stacked` (e.g. fixed/variable). */
export function BarChart({ data, mode, height = 168 }: { data: BarDatum[]; mode: 'grouped' | 'stacked'; height?: number }) {
  const max = Math.max(
    1,
    ...data.map(d =>
      mode === 'stacked'
        ? d.segments.reduce((sum, seg) => sum + Math.abs(seg.value), 0)
        : Math.max(0, ...d.segments.map(seg => Math.abs(seg.value)))
    )
  )

  return (
    <div className="stat-chart">
      <div className="stat-bars" style={{ height }}>
        {data.map((d, i) => (
          <div className="stat-col" key={d.label + i}>
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
      </div>
      <div className="stat-axis">
        {data.map((d, i) => <div key={d.label + i} className="stat-axis-label mono">{d.label}</div>)}
      </div>
    </div>
  )
}

export interface RankedItem { id: string | number; label: string; value: number; share: number | null; color: string; muted?: boolean }

/** Horizontal ranked bars (category breakdown). `value` is signed; bars use magnitude. */
export function RankedBars({ items, maxValue, formatValue }: { items: RankedItem[]; maxValue: number; formatValue: (v: number) => string }) {
  const max = Math.max(1, maxValue)
  return (
    <div className="stat-rank">
      {items.map((it, i) => (
        <div className={'stat-rank-row' + (it.muted ? ' muted' : '')} key={it.id}>
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
        </div>
      ))}
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
