import { useState, useEffect, useRef } from 'react'
import { useTranslation } from 'react-i18next'
import { api } from '../lib/api'
import { Modal, Btn } from './ui'
import Icon from './Icon'

interface TradeRepublicPairingModalProps {
  title: string
  /** Initiates pairing (create or reconnect); resolves to {id, pairing_id, countdown_seconds}. */
  initiate: () => Promise<Response>
  onConnected: () => void
  onClose: () => void
}

/**
 * Two-step Trade Republic pairing. On open it calls `initiate` (which starts a
 * web login and triggers an app push), then collects the 4–6 digit code and
 * completes via /confirm_2fa. "Send a new code" simply re-initiates — the
 * cleanest way to get a fresh push without a dedicated resend endpoint.
 */
export default function TradeRepublicPairingModal({ title, initiate, onConnected, onClose }: TradeRepublicPairingModalProps) {
  const { t } = useTranslation()
  const [phase, setPhase] = useState<'starting' | 'code' | 'connecting'>('starting')
  const [connectionId, setConnectionId] = useState<number | null>(null)
  const [pairingId, setPairingId] = useState<string | null>(null)
  const [code, setCode] = useState('')
  const [error, setError] = useState('')
  const [info, setInfo] = useState('')
  const [startFailed, setStartFailed] = useState(false)

  // Keep the latest initiate without making it an effect dependency, and guard
  // against React StrictMode's double-invoke so we never send two pushes.
  const initiateRef = useRef(initiate)
  initiateRef.current = initiate
  const startedRef = useRef(false)

  const doStart = async () => {
    setPhase('starting'); setError(''); setInfo(''); setStartFailed(false)
    try {
      const r = await initiateRef.current()
      const data = await r.json().catch(() => ({}))
      if (r.ok && data.pairing_id) {
        setConnectionId(data.id)
        setPairingId(data.pairing_id)
        setPhase('code')
      } else {
        setError(data.error === 'scraper_unavailable' ? t('trade_republic.scraper_unavailable') : (data.message || t('trade_republic.start_error')))
        setStartFailed(true)
        setPhase('code')
      }
    } catch {
      setError(t('trade_republic.start_error'))
      setStartFailed(true)
      setPhase('code')
    }
  }

  useEffect(() => {
    if (startedRef.current) return
    startedRef.current = true
    doStart()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const submit = async () => {
    if (!connectionId || !pairingId || code.trim().length === 0 || phase === 'connecting') return
    setPhase('connecting'); setError(''); setInfo('')
    try {
      const r = await api(`/api/v1/bank_connections/${connectionId}/confirm_2fa`, {
        method: 'POST',
        body: { pairing_id: pairingId, code: code.trim() },
      })
      if (r.ok) { onConnected(); return }
      const data = await r.json().catch(() => ({}))
      const msg = data.error === 'pairing_expired' ? t('trade_republic.code_expired')
        : data.error === 'pairing_failed' ? t('trade_republic.code_wrong')
        : data.error === 'scraper_unavailable' ? t('trade_republic.scraper_unavailable')
        : (data.message || t('common.error'))
      setError(msg)
      setPhase('code')
    } catch {
      setError(t('common.error'))
      setPhase('code')
    }
  }

  const resend = async () => {
    setCode('')
    await doStart()
    setInfo(t('trade_republic.code_resent'))
  }

  const busy = phase === 'starting' || phase === 'connecting'

  return (
    <Modal
      title={title}
      icon="link"
      onClose={onClose}
      closeLabel={t('common.close')}
      subtitle={phase === 'starting' ? undefined : t('trade_republic.code_sent_note')}
      footer={
        <>
          <Btn variant="ghost" onClick={onClose}>{t('common.cancel')}</Btn>
          <Btn variant="primary" onClick={submit} disabled={busy || startFailed || code.trim().length === 0}>
            {phase === 'connecting' ? t('trade_republic.connecting') : t('trade_republic.connect')}
          </Btn>
        </>
      }
    >
      {phase === 'starting' ? (
        <div className="text-center py-6">
          <Icon name="sync" size={28} className="spin text-brass-ink" />
          <div className="text-ink-muted text-[13px] mt-3">{t('trade_republic.sending')}</div>
        </div>
      ) : startFailed ? (
        <div className="grid gap-3 justify-items-start">
          <div className="flex items-start gap-2 text-danger text-[12.5px] font-medium">
            <Icon name="alert" size={15} className="shrink-0 mt-px" />{error}
          </div>
          <Btn variant="secondary" icon="sync" onClick={doStart}>{t('trade_republic.retry_start')}</Btn>
        </div>
      ) : (
        <div className="grid gap-[15px]">
          <label className="block">
            <span className="field-label">{t('trade_republic.code_label')}</span>
            <input
              className="field field-mono text-center text-lg tracking-[0.4em]"
              value={code}
              onChange={e => setCode(e.target.value.replace(/\D/g, '').slice(0, 6))}
              onKeyDown={e => { if (e.key === 'Enter') submit() }}
              inputMode="numeric"
              autoComplete="one-time-code"
              placeholder={t('trade_republic.code_placeholder')}
              autoFocus
            />
          </label>

          {error && (
            <div className="flex items-start gap-2 text-danger text-[12.5px] font-medium">
              <Icon name="alert" size={15} className="shrink-0 mt-px" />{error}
            </div>
          )}
          {info && !error && (
            <div className="flex items-center gap-2 text-income text-[12.5px] font-medium">
              <Icon name="check" size={15} />{info}
            </div>
          )}

          <button type="button" onClick={resend} disabled={busy}
            className="focus-inset inline-flex items-center gap-1.5 text-ink-muted text-[12.5px] font-[550] justify-self-start disabled:opacity-50">
            <Icon name="sync" size={14} />{t('trade_republic.resend')}
          </button>

          <p className="text-ink-faint text-[11.5px] leading-[1.5] border-t border-line pt-3">
            {t('trade_republic.disclaimer')}
          </p>
        </div>
      )}
    </Modal>
  )
}
