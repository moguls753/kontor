import { useState, useEffect, useRef } from 'react'
import { useTranslation } from 'react-i18next'
import { api } from '../lib/api'
import { Modal, Btn } from './ui'
import Icon from './Icon'

interface EasybankPairingModalProps {
  title: string
  /**
   * Initiates the login (create or reconnect). Resolves to either an authorized
   * connection JSON (no mTAN) or an mTAN challenge {id, mtan_required, pairing_id,
   * masked_phone, reference, expires_in}.
   */
  initiate: () => Promise<Response>
  onConnected: () => void
  onClose: () => void
}

/**
 * easybank login. Unlike Trade Republic, a device-paired profile usually logs in
 * password-only: on `initiate` we POST the login and, if the response is an
 * authorized connection (no `mtan_required`), we connect and close immediately —
 * no code step. Only when the sidecar demands an SMS mTAN do we render the
 * code-entry step (masked phone + reference + a countdown from `expires_in`),
 * submitting via /confirm_2fa. "Send a new code" re-initiates the login.
 */
export default function EasybankPairingModal({ title, initiate, onConnected, onClose }: EasybankPairingModalProps) {
  const { t } = useTranslation()
  const [phase, setPhase] = useState<'starting' | 'code' | 'connecting'>('starting')
  const [connectionId, setConnectionId] = useState<number | null>(null)
  const [pairingId, setPairingId] = useState<string | null>(null)
  const [maskedPhone, setMaskedPhone] = useState('')
  const [reference, setReference] = useState('')
  const [secondsLeft, setSecondsLeft] = useState<number | null>(null)
  const [code, setCode] = useState('')
  const [error, setError] = useState('')
  const [info, setInfo] = useState('')
  const [startFailed, setStartFailed] = useState(false)

  // Keep the latest initiate without making it an effect dependency, and guard
  // against React StrictMode's double-invoke so we never send two requests.
  const initiateRef = useRef(initiate)
  initiateRef.current = initiate
  const startedRef = useRef(false)

  const doStart = async () => {
    setPhase('starting'); setError(''); setInfo(''); setStartFailed(false)
    try {
      const r = await initiateRef.current()
      const data = await r.json().catch(() => ({}))
      if (r.ok && data.mtan_required && data.pairing_id) {
        // SMS challenge: collect the mTAN.
        setConnectionId(data.id)
        setPairingId(data.pairing_id)
        setMaskedPhone(data.masked_phone || '')
        setReference(data.reference || '')
        setSecondsLeft(typeof data.expires_in === 'number' ? data.expires_in : null)
        setPhase('code')
      } else if (r.ok) {
        // Device-paired profile — logged in password-only, no mTAN. Done.
        onConnected()
      } else {
        const msg = data.error === 'login_failed' ? t('easybank.login_failed')
          : data.error === 'session_expired' ? t('easybank.session_expired')
          : data.error === 'scraper_unavailable' ? t('easybank.scraper_unavailable')
          : (data.message || t('easybank.start_error'))
        setError(msg)
        setStartFailed(true)
        setPhase('code')
      }
    } catch {
      setError(t('easybank.start_error'))
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

  // Live mTAN countdown — ticks down to 0 and stops.
  useEffect(() => {
    if (phase !== 'code' || secondsLeft == null || secondsLeft <= 0) return
    const timer = setInterval(() => {
      setSecondsLeft(s => (s == null || s <= 1 ? 0 : s - 1))
    }, 1000)
    return () => clearInterval(timer)
  }, [phase, secondsLeft])

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
      const msg = data.error === 'mtan_failed' ? t('easybank.code_wrong')
        : data.error === 'session_expired' ? t('easybank.session_expired')
        : data.error === 'scraper_unavailable' ? t('easybank.scraper_unavailable')
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
    setInfo(t('easybank.code_resent'))
  }

  const busy = phase === 'starting' || phase === 'connecting'
  const expired = secondsLeft != null && secondsLeft <= 0
  const countdownLabel = secondsLeft != null && secondsLeft > 0
    ? `${Math.floor(secondsLeft / 60)}:${String(secondsLeft % 60).padStart(2, '0')}`
    : null

  return (
    <Modal
      title={title}
      icon="link"
      onClose={onClose}
      closeLabel={t('common.close')}
      subtitle={phase === 'starting' ? undefined : t('easybank.code_sent_note')}
      footer={
        <>
          <Btn variant="ghost" onClick={onClose}>{t('common.cancel')}</Btn>
          <Btn variant="primary" onClick={submit} disabled={busy || startFailed || code.trim().length === 0}>
            {phase === 'connecting' ? t('easybank.connecting') : t('easybank.connect')}
          </Btn>
        </>
      }
    >
      {phase === 'starting' ? (
        <div className="text-center py-6">
          <Icon name="sync" size={28} className="spin text-brass-ink" />
          <div className="text-ink-muted text-[13px] mt-3">{t('easybank.signing_in')}</div>
        </div>
      ) : startFailed ? (
        <div className="grid gap-3 justify-items-start">
          <div className="flex items-start gap-2 text-danger text-[12.5px] font-medium">
            <Icon name="alert" size={15} className="shrink-0 mt-px" />{error}
          </div>
          <Btn variant="secondary" icon="sync" onClick={doStart}>{t('easybank.retry_start')}</Btn>
        </div>
      ) : (
        <div className="grid gap-[15px]">
          {maskedPhone && (
            <div className="flex items-center justify-between gap-3 bg-surface-2 border border-line rounded-[6px] px-[13px] py-[9px]">
              <span className="flex items-center gap-2 text-ink-muted text-[12.5px] font-[550]">
                <Icon name="shield" size={15} className="text-brass-ink" />{t('easybank.sent_to', { phone: maskedPhone })}
              </span>
              {countdownLabel && <span className="mono text-[12.5px] text-ink-faint">{countdownLabel}</span>}
            </div>
          )}

          <label className="block">
            <span className="field-label">{t('easybank.code_label')}</span>
            <input
              className="field field-mono text-center text-lg tracking-[0.4em]"
              value={code}
              onChange={e => setCode(e.target.value.replace(/\D/g, '').slice(0, 8))}
              onKeyDown={e => { if (e.key === 'Enter') submit() }}
              inputMode="numeric"
              autoComplete="one-time-code"
              placeholder={t('easybank.code_placeholder')}
              autoFocus
            />
          </label>

          {reference && (
            <p className="text-ink-faint text-[11.5px]">
              {t('easybank.reference', { reference })}
            </p>
          )}

          {error && (
            <div className="flex items-start gap-2 text-danger text-[12.5px] font-medium">
              <Icon name="alert" size={15} className="shrink-0 mt-px" />{error}
            </div>
          )}
          {expired && !error && (
            <div className="flex items-start gap-2 text-danger text-[12.5px] font-medium">
              <Icon name="alert" size={15} className="shrink-0 mt-px" />{t('easybank.code_expired')}
            </div>
          )}
          {info && !error && !expired && (
            <div className="flex items-center gap-2 text-income text-[12.5px] font-medium">
              <Icon name="check" size={15} />{info}
            </div>
          )}

          <button type="button" onClick={resend} disabled={busy}
            className="focus-inset inline-flex items-center gap-1.5 text-ink-muted text-[12.5px] font-[550] justify-self-start disabled:opacity-50">
            <Icon name="sync" size={14} />{t('easybank.resend')}
          </button>

          <p className="text-ink-faint text-[11.5px] leading-[1.5] border-t border-line pt-3">
            {t('easybank.disclaimer')}
          </p>
        </div>
      )}
    </Modal>
  )
}
