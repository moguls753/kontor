/* ============================================================================
   KONTOR — shared UI primitives for the Counting House design.
   These are presentation-only; all data fetching/state stays in the pages.
   ============================================================================ */
import { useEffect, useRef } from 'react'
import { createPortal } from 'react-dom'
import type { ReactNode } from 'react'
import Icon from './Icon'
import type { IconName } from './Icon'

/* ---- Locale-aware money formatting (strings or null) -------------------- */
function getLocale(): string {
  return localStorage.getItem('language') === 'de' ? 'de-DE' : 'en-GB'
}

interface MoneyResult { text: string; isNull: boolean; sign: number }

/** Signed money figure with explicit +/− glyph (real minus U+2212). */
function money(value: string | number | null | undefined, currency = 'EUR'): MoneyResult {
  if (value == null || value === '') return { text: '—', isNull: true, sign: 0 }
  const num = typeof value === 'number' ? value : parseFloat(value)
  if (Number.isNaN(num)) return { text: '—', isNull: true, sign: 0 }
  const fmt = new Intl.NumberFormat(getLocale(), {
    style: 'currency', currency: currency || 'EUR',
    minimumFractionDigits: 2, maximumFractionDigits: 2,
    signDisplay: 'never',
  })
  const sign = num > 0 ? 1 : num < 0 ? -1 : 0
  const body = fmt.format(Math.abs(num))
  const glyph = sign > 0 ? '+ ' : sign < 0 ? '− ' : ''
  return { text: glyph + body, isNull: false, sign }
}

/** Plain (unsigned) balance — for hero/account balances. null → "—". */
export function balance(value: string | number | null | undefined, currency = 'EUR'): MoneyResult {
  if (value == null || value === '') return { text: '—', isNull: true, sign: 0 }
  const num = typeof value === 'number' ? value : parseFloat(value)
  if (Number.isNaN(num)) return { text: '—', isNull: true, sign: 0 }
  const fmt = new Intl.NumberFormat(getLocale(), {
    style: 'currency', currency: currency || 'EUR',
    minimumFractionDigits: 2, maximumFractionDigits: 2,
  })
  return { text: fmt.format(num), isNull: false, sign: num < 0 ? -1 : 1 }
}

/* ---- Stable per-category hue (the real API has no hue) ------------------ */
export function hueFor(seed: string | number): number {
  const s = String(seed)
  let h = 0
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0
  return h % 360
}
export function catColor(hue: number): string {
  return `oklch(0.58 0.11 ${hue})`
}

/* ---- Name → 1–2 letter monogram (counterparty avatars, account tiles) --- */
export function initials(name: string): string {
  const parts = (name || '').replace(/[^\p{L}\p{N} ]/gu, '').trim().split(/\s+/).filter(Boolean)
  if (parts.length === 0) return '—'
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase()
  return (parts[0][0] + parts[1][0]).toUpperCase()
}

/* ---- Button ------------------------------------------------------------- */
type Variant = 'primary' | 'secondary' | 'ghost' | 'danger'
interface BtnProps {
  variant?: Variant
  size?: 'sm'
  icon?: IconName
  iconRight?: IconName
  children?: ReactNode
  className?: string
  onClick?: () => void
  disabled?: boolean
  title?: string
  type?: 'button' | 'submit'
}
export function Btn({ variant = 'secondary', size, icon, iconRight, children, className = '', onClick, disabled, title, type = 'button' }: BtnProps) {
  const cls = ['btn', 'btn-' + variant, size === 'sm' ? 'btn-sm' : '', children == null ? 'btn-icon' : '', className]
    .filter(Boolean).join(' ')
  return (
    <button className={cls} onClick={onClick} disabled={disabled} title={title} type={type} aria-label={children == null ? title : undefined}>
      {icon && <Icon name={icon} size={size === 'sm' ? 15 : 16} />}
      {children}
      {iconRight && <Icon name={iconRight} size={size === 'sm' ? 15 : 16} />}
    </button>
  )
}

/* ---- Amount: signed money figure with deliberate sign semantics --------- */
interface AmountProps {
  value: string | number | null | undefined
  currency?: string
  signed?: boolean
  className?: string
  forceNegative?: boolean
}
export function Amount({ value, currency = 'EUR', signed = true, className = '', forceNegative }: AmountProps) {
  const r = signed ? money(value, currency) : balance(value, currency)
  let tone = 'amt-neg'
  if (r.isNull) tone = 'amt-null'
  else if (signed && r.sign > 0) tone = 'amt-pos'
  else if (forceNegative) tone = 'amt-neg'
  return <span className={`amt ${tone} ${className}`.trim()}>{r.text}</span>
}

/* ---- Category chip ------------------------------------------------------ */
export function CategoryChip({ name, uncategorisedLabel }: { name: string | null; uncategorisedLabel: string }) {
  if (!name) {
    return (
      <span className="chip uncat">
        <span className="tick bg-brass" />
        {uncategorisedLabel}
      </span>
    )
  }
  return (
    <span className="chip">
      <span className="tick" style={{ background: catColor(hueFor(name)) }} />
      {name}
    </span>
  )
}

/* ---- Counterparty avatar token ------------------------------------------ */
export function CpAvatar({ name, sign }: { name: string; sign: number }) {
  return (
    <span className={'cp-avatar' + (sign > 0 ? ' pos' : '')} aria-hidden="true">
      {initials(name)}
    </span>
  )
}

/* ---- Connection status → badge ------------------------------------------ */
export function StatusBadge({ status, label }: { status: string; label: string }) {
  const cls = status === 'authorized' ? 'badge-ok'
    : status === 'pending' ? 'badge-warn'
    : status === 'expired' ? 'badge-warn'
    : 'badge-err'
  return <span className={'badge ' + cls}><span className="dot" />{label}</span>
}

/* ---- Modal (Esc to close, autofocus first focusable) -------------------- */
interface ModalProps {
  title: string
  subtitle?: string
  children?: ReactNode
  footer?: ReactNode
  onClose?: () => void
  icon?: IconName
  closeLabel?: string
  size?: 'default' | 'lg'
}
export function Modal({ title, subtitle, children, footer, onClose, icon, closeLabel = 'Close', size = 'default' }: ModalProps) {
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose?.() }
    document.addEventListener('keydown', onKey)
    const node = ref.current
    // Remember the trigger so focus returns to it on close (a11y: no focus loss to <body>).
    const prevFocus = document.activeElement as HTMLElement | null
    const focusable = node?.querySelector<HTMLElement>('button, [href], input, select, textarea, [tabindex]')
    focusable?.focus()
    return () => {
      document.removeEventListener('keydown', onKey)
      if (prevFocus && document.body.contains(prevFocus)) prevFocus.focus()
    }
  }, [onClose])
  // Portal to <body> so the fixed overlay always covers the full viewport —
  // a transformed/animated ancestor (e.g. an animated panel) would otherwise
  // become the containing block and trap the overlay inside it.
  return createPortal(
    <div className="overlay" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose?.() }}>
      <div className={'modal' + (size === 'lg' ? ' modal-lg' : '')} ref={ref} role="dialog" aria-modal="true" aria-label={title}>
        <div className="modal-head">
          <div className="flex gap-[13px] items-start min-w-0">
            {icon && (
              <span className="icon-tile icon-tile-brass">
                <Icon name={icon} size={18} />
              </span>
            )}
            <div className="min-w-0">
              <div className="font-semibold text-base tracking-[-0.01em]">{title}</div>
              {subtitle && <div className="text-ink-muted text-[12.5px] mt-0.5">{subtitle}</div>}
            </div>
          </div>
          {onClose && (
            <button className="ibtn btn-sm w-[30px] h-[30px]" onClick={onClose} aria-label={closeLabel}>
              <Icon name="close" size={16} />
            </button>
          )}
        </div>
        <div className="modal-body">{children}</div>
        {footer && <div className="modal-foot">{footer}</div>}
      </div>
    </div>,
    document.body,
  )
}

/* ---- Select (native, styled) -------------------------------------------- */
interface SelectProps {
  value: string
  onChange: (e: React.ChangeEvent<HTMLSelectElement>) => void
  children: ReactNode
  className?: string
  ariaLabel?: string
}
export function Select({ value, onChange, children, className = '', ariaLabel }: SelectProps) {
  return (
    <div className={'search relative p-0 ' + className}>
      <select value={value} onChange={onChange} aria-label={ariaLabel}
        className="appearance-none bg-transparent border-none h-10 pl-[13px] pr-[34px] text-ink w-full outline-none">
        {children}
      </select>
      <Icon name="chevronDown" size={15} className="absolute right-[11px] top-1/2 -translate-y-1/2 text-ink-faint pointer-events-none" />
    </div>
  )
}

/* ---- Empty state -------------------------------------------------------- */
export function Empty({ icon, title, body, children }: { icon?: IconName; title: string; body?: string; children?: ReactNode }) {
  return (
    <div className="empty">
      <span className="empty-mark">{icon && <Icon name={icon} size={24} />}</span>
      <div className="font-semibold text-base">{title}</div>
      {body && <div className="text-ink-muted text-[13.5px] max-w-[380px] leading-[1.55]">{body}</div>}
      {children && <div className="mt-4">{children}</div>}
    </div>
  )
}

/* ---- Section label (ledger eyebrow) ------------------------------------- */
export function Eyebrow({ children, className = '' }: { children: ReactNode; className?: string }) {
  return <div className={('eyebrow ' + className).trim()}>{children}</div>
}
