import { useState, useEffect, useRef } from 'react'
import { useTranslation } from 'react-i18next'
import { api } from '../lib/api'
import { Btn } from './ui'
import Icon from './Icon'

interface Props {
  // called after a successful enqueue so the page can refetch once the pipeline
  // has had a moment to run
  onStarted?: () => void
}

// Understated single action replacing the old "Scannen" / "Kategorisieren"
// buttons. POSTs to the recurring detect endpoint, which now enqueues the FULL
// post-sync pipeline (categorize → match transfers → detect recurring) async.
// Surfaces a lightweight toast instead of a modal with synchronous counts.
export default function RecalculateButton({ onStarted }: Props) {
  const { t } = useTranslation()
  const [busy, setBusy] = useState(false)
  const [toast, setToast] = useState<{ kind: 'ok' | 'err'; text: string } | null>(null)
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  useEffect(() => () => { if (timerRef.current) clearTimeout(timerRef.current) }, [])

  const showToast = (kind: 'ok' | 'err', text: string) => {
    setToast({ kind, text })
    if (timerRef.current) clearTimeout(timerRef.current)
    timerRef.current = setTimeout(() => setToast(null), 6000)
  }

  const handleClick = async () => {
    setBusy(true)
    try {
      const r = await api('/api/v1/recurring/detect', { method: 'POST' })
      if (r.ok) {
        showToast('ok', t('common.recalculate_started'))
        // give the async pipeline a beat, then let the page refetch
        if (onStarted) timerRef.current = setTimeout(() => onStarted(), 4000)
      } else {
        showToast('err', t('common.recalculate_error'))
      }
    } catch {
      showToast('err', t('common.recalculate_error'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <Btn variant="ghost" size="sm" icon="sync" onClick={handleClick} disabled={busy}
        title={t('common.recalculate')}>
        {t('common.recalculate')}
      </Btn>
      {toast && (
        <div className="toast-wrap" role="status" aria-live="polite">
          <div className={`toast ${toast.kind === 'ok' ? 'ok' : 'err'}`}>
            <Icon name={toast.kind === 'ok' ? 'check' : 'alert'} size={18}
              className={'shrink-0 mt-px ' + (toast.kind === 'ok' ? 'text-income' : 'text-danger')} />
            <div className="flex-1 min-w-0">
              <div className="toast-title">{toast.text}</div>
            </div>
            <button className="ibtn btn-sm w-[26px] h-[26px]" onClick={() => setToast(null)} aria-label={t('common.close')}>
              <Icon name="close" size={14} />
            </button>
          </div>
        </div>
      )}
    </>
  )
}
