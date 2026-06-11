import { useState, useRef, useEffect, type FormEvent } from 'react'
import { Btn, Select, Eyebrow } from './ui'
import Icon from './Icon'
import { formatAmount } from '../lib/format'
import {
  type ScenarioAdjustment, type ScenarioKind,
  newId, parseAmount, monthOptions, offsetShort,
} from '../lib/scenario'

interface ScenarioEditorProps {
  adjustments: ScenarioAdjustment[]
  onAdd: (a: ScenarioAdjustment) => void
  onRemove: (id: string) => void
  onReset: () => void
  locale: string
  t: (k: string, o?: Record<string, unknown>) => string
}

// The "Szenario · Was-wäre-wenn" editor: an inline add-form (no modal — playground
// feel) + a chip-list of assumptions. Pure UI over the parent's scenario state; the
// projection itself lives in ForecastPanel.
export default function ScenarioEditor({ adjustments, onAdd, onRemove, onReset, locale, t }: ScenarioEditorProps) {
  const tx = (k: string, o?: Record<string, unknown>) => t(`statistics.forecast.scenario.${k}`, o)

  const [open, setOpen] = useState(false)
  const [kind, setKind] = useState<ScenarioKind>('recurring')
  const [sign, setSign] = useState<1 | -1>(-1)
  const [isSavings, setIsSavings] = useState(false)
  const [amountStr, setAmountStr] = useState('')
  const [label, setLabel] = useState('')
  const [fromOffset, setFromOffset] = useState(1)

  const amountRef = useRef<HTMLInputElement>(null)
  const triggerRef = useRef<HTMLButtonElement>(null)
  const wasOpen = useRef(false)

  const months = monthOptions(locale)
  const amount = parseAmount(amountStr)
  const valid = !isNaN(amount) && amount > 0

  // Keyboard focus management: autofocus the amount field when the form opens; return
  // focus to the "+ Annahme" trigger once it closes. The trigger is unmounted WHILE the
  // form is open, so a synchronous focus() in close() would hit a null ref — do it here,
  // post-render, when the trigger is back in the DOM.
  useEffect(() => {
    if (open) amountRef.current?.focus()
    else if (wasOpen.current) triggerRef.current?.focus()
    wasOpen.current = open
  }, [open])

  const resetForm = () => {
    setKind('recurring'); setSign(-1); setIsSavings(false)
    setAmountStr(''); setLabel(''); setFromOffset(1)
  }
  const close = () => { setOpen(false); resetForm() }

  const submit = (e: FormEvent) => {
    e.preventDefault()
    if (!valid) return
    onAdd({
      id: newId(),
      kind,
      label: label.trim(),
      amount: sign * amount, // sign comes ONLY from the toggle
      lens: sign === -1 && isSavings ? 'liquid' : 'both',
      fromOffset,
    })
    close()
  }

  const n = adjustments.length

  return (
    <div className="fc-sc">
      <div className="fc-sc-head">
        <Eyebrow>{tx('title')}</Eyebrow>
        {n > 0 && (
          <div className="fc-sc-head-right">
            <span className="fc-sc-active">{tx('active', { n })}</span>
            <button type="button" className="fc-sc-reset" onClick={onReset}>{tx('reset')}</button>
          </div>
        )}
      </div>

      <p className="fc-sc-sub">{tx('subtitle')}</p>

      {n > 0 && (
        <ul className="fc-sc-chips">
          {adjustments.map(a => (
            <li key={a.id} className={'fc-sc-chip' + (a.lens === 'liquid' ? ' is-savings' : '')}>
              <span className={'fc-sc-chip-dir ' + (a.amount >= 0 ? 'in' : 'out')} aria-hidden="true">{a.amount >= 0 ? '↑' : '↓'}</span>
              <span className="fc-sc-chip-body">
                {a.label && <span className="fc-sc-chip-label">{a.label}</span>}
                <span className="fc-sc-chip-meta">
                  <span className="fc-sc-chip-amt">{(a.amount >= 0 ? '+ ' : '− ') + formatAmount(Math.abs(a.amount))}{a.kind === 'recurring' ? '/Mt' : ''}</span>
                  {' · '}{tx(a.kind === 'recurring' ? 'from' : 'on')} {offsetShort(a.fromOffset, locale)}
                  {a.lens === 'liquid' && <span className="fc-sc-chip-tag">{tx('savings')}</span>}
                </span>
              </span>
              <button type="button" className="ibtn fc-sc-chip-x" onClick={() => onRemove(a.id)} aria-label={`${tx('remove')}${a.label ? ': ' + a.label : ''}`}>×</button>
            </li>
          ))}
        </ul>
      )}

      {!open ? (
        <button ref={triggerRef} type="button" className="fc-sc-add" onClick={() => setOpen(true)}>
          <Icon name="plus" size={14} />{tx('add')}
        </button>
      ) : (
        <form className="fc-sc-form" onSubmit={submit}>
          <div className="fc-sc-row">
            <div className="segmented" role="group" aria-label={tx('group_kind')}>
              <button type="button" className={kind === 'recurring' ? 'on' : ''} aria-pressed={kind === 'recurring'} onClick={() => setKind('recurring')}>{tx('kind_recurring')}</button>
              <button type="button" className={kind === 'oneoff' ? 'on' : ''} aria-pressed={kind === 'oneoff'} onClick={() => setKind('oneoff')}>{tx('kind_oneoff')}</button>
            </div>
            <div className="segmented" role="group" aria-label={tx('group_direction')}>
              <button type="button" className={sign === 1 ? 'on' : ''} aria-pressed={sign === 1} onClick={() => { setSign(1); setIsSavings(false) }}>+&nbsp;{tx('income')}</button>
              <button type="button" className={sign === -1 ? 'on' : ''} aria-pressed={sign === -1} onClick={() => setSign(-1)}>−&nbsp;{tx('expense')}</button>
            </div>
          </div>

          <div className="fc-sc-row">
            <label className="fc-sc-field">
              <span className="fc-sc-flabel">{tx('amount')}</span>
              <div className={'fc-sc-amt' + (sign === 1 ? ' is-in' : '')}>
                <span className="fc-sc-amt-sign" aria-hidden="true">{sign === 1 ? '+' : '−'}</span>
                <input
                  ref={amountRef}
                  className="field field-mono fc-sc-amt-input"
                  inputMode="decimal"
                  value={amountStr}
                  onChange={e => setAmountStr(e.target.value)}
                  placeholder={tx('amount_ph')}
                  aria-label={tx('amount')}
                />
                <span className="fc-sc-amt-cur" aria-hidden="true">€</span>
              </div>
            </label>
            <label className="fc-sc-field">
              <span className="fc-sc-flabel">{tx(kind === 'recurring' ? 'from' : 'on')}</span>
              <Select value={String(fromOffset)} onChange={e => setFromOffset(Number(e.target.value))} ariaLabel={tx(kind === 'recurring' ? 'from' : 'on')}>
                {months.map(m => <option key={m.offset} value={m.offset}>{m.label}</option>)}
              </Select>
            </label>
          </div>

          <div className="fc-sc-row">
            <label className="fc-sc-field fc-sc-field-grow">
              <span className="fc-sc-flabel">{tx('label')}</span>
              <input className="field" value={label} onChange={e => setLabel(e.target.value)} placeholder={tx('label_ph')} maxLength={40} />
            </label>
            {sign === -1 && (
              <label className={'fc-sc-savings' + (isSavings ? ' on' : '')} title={tx('savings_hint')}>
                <input type="checkbox" checked={isSavings} onChange={e => setIsSavings(e.target.checked)} />
                <span>{tx('savings')}</span>
              </label>
            )}
          </div>

          <div className="fc-sc-actions">
            <Btn variant="ghost" size="sm" onClick={close}>{tx('cancel')}</Btn>
            <Btn variant="primary" size="sm" type="submit" disabled={!valid}>{tx('save')}</Btn>
          </div>
        </form>
      )}
    </div>
  )
}
