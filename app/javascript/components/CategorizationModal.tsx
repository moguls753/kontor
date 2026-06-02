import { useState, useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { api } from '../lib/api'
import type { View } from './SidebarNav'
import { Modal, Btn, Eyebrow } from './ui'
import Icon from './Icon'

interface Props {
  onClose: (didCategorize: boolean) => void
  onNavigate?: (view: View) => void
}

type Step = 'loading' | 'confirm' | 'running' | 'done' | 'error'

export default function CategorizationModal({ onClose, onNavigate }: Props) {
  const { t } = useTranslation()
  const [step, setStep] = useState<Step>('loading')
  const [count, setCount] = useState(0)
  const [results, setResults] = useState<{ total: number; categorized: number; failed: number; breakdown?: Record<string, number> } | null>(null)

  useEffect(() => {
    api('/api/v1/transactions?uncategorized=true&per=1')
      .then(r => r.ok ? r.json() : null)
      .then(data => {
        if (data) {
          setCount(data.meta.total)
          setStep(data.meta.total > 0 ? 'confirm' : 'done')
          if (data.meta.total === 0) setResults({ total: 0, categorized: 0, failed: 0 })
        } else {
          setStep('error')
        }
      })
      .catch(() => setStep('error'))
  }, [])

  const handleCategorize = async () => {
    setStep('running')
    try {
      const r = await api('/api/v1/transactions/categorize', { method: 'POST' })
      if (r.ok) {
        setResults(await r.json())
        setStep('done')
      } else {
        setStep('error')
      }
    } catch {
      setStep('error')
    }
  }

  const didCategorize = results !== null && results.categorized > 0
  const dismissable = step !== 'running' && step !== 'loading'
  const handleClose = () => { if (dismissable) onClose(didCategorize) }

  const unmatched = results ? results.total - results.categorized - results.failed : 0

  let footer: React.ReactNode = null
  if (step === 'confirm') {
    footer = (
      <>
        <Btn variant="ghost" onClick={() => onClose(false)}>{t('common.cancel')}</Btn>
        <Btn variant="primary" icon="scan" onClick={handleCategorize}>{t('transactions.categorize')}</Btn>
      </>
    )
  } else if (step === 'running') {
    footer = (
      <Btn variant="primary" disabled>
        <Icon name="sync" size={15} className="spin" />{t('transactions.categorizing')}
      </Btn>
    )
  } else if (step === 'done' || step === 'error') {
    footer = <Btn variant="ghost" onClick={() => onClose(didCategorize)}>{t('transactions.categorize_close')}</Btn>
  }

  return (
    <Modal title={t('transactions.categorize_title')} icon="scan" onClose={dismissable ? handleClose : undefined} footer={footer} closeLabel={t('common.close')}>
      {step === 'loading' && (
        <div className="flex items-center gap-[11px] py-1">
          <Icon name="sync" size={18} className="spin text-ink-muted" />
          <span className="text-ink-muted text-[13.5px]">{t('common.loading')}</span>
        </div>
      )}

      {step === 'confirm' && (
        <>
          <p className="text-ink-muted text-[13.5px] leading-[1.6]">{t('transactions.categorize_confirm', { count })}</p>
          <div className="mt-4 flex items-center gap-[9px] px-[13px] py-2.5 bg-surface-2 border border-line rounded-md">
            <Icon name="shield" size={17} className="text-income shrink-0" />
            <span className="text-[12.5px] font-medium">{t('transactions.categorize_privacy')}</span>
          </div>
        </>
      )}

      {step === 'running' && (
        <div className="flex items-center gap-[11px] py-1">
          <Icon name="sync" size={18} className="spin text-brass-ink" />
          <div>
            <div className="font-semibold text-sm">{t('transactions.categorizing')}</div>
            <div className="text-ink-muted text-[12.5px] mt-px">{t('transactions.categorize_wait')}</div>
          </div>
        </div>
      )}

      {step === 'done' && results && (
        results.total === 0 ? (
          <p className="text-ink-muted text-[13.5px]">{t('transactions.categorize_none')}</p>
        ) : (
          <div className="pb-1.5">
            <div className="flex items-center gap-[11px] mb-[14px]">
              <span className="icon-tile icon-tile-ok"><Icon name="check" size={19} /></span>
              <div className="font-semibold text-[14.5px]">{t('transactions.categorize_done')}</div>
            </div>
            <div className={'flex gap-6' + (results.breakdown && Object.keys(results.breakdown).length > 0 ? ' mb-1' : '')}>
              <div>
                <div className="mono amt-pos text-2xl font-medium">{results.categorized}</div>
                <Eyebrow className="mt-[3px]">{t('transactions.categorize_matched')}</Eyebrow>
              </div>
              {results.failed > 0 && (
                <div>
                  <div className="mono text-2xl font-medium text-danger">{results.failed}</div>
                  <Eyebrow className="mt-[3px]">{t('transactions.categorize_errors')}</Eyebrow>
                </div>
              )}
              {unmatched > 0 && (
                <div>
                  <div className="mono text-ink-faint text-2xl font-medium">{unmatched}</div>
                  <Eyebrow className="mt-[3px]">{t('transactions.categorize_unmatched')}</Eyebrow>
                </div>
              )}
            </div>

            {results.breakdown && Object.keys(results.breakdown).length > 0 && (
              <div className="border-t border-line pt-3 mt-[14px] max-h-[180px] overflow-y-auto">
                {Object.entries(results.breakdown).sort(([, a], [, b]) => b - a).map(([name, c]) => (
                  <div key={name} className="flex items-center justify-between py-1">
                    <span className="text-[13px] overflow-hidden text-ellipsis whitespace-nowrap mr-4">{name}</span>
                    <span className="mono text-ink-muted text-[13px] font-[550] shrink-0">{c}</span>
                  </div>
                ))}
              </div>
            )}

            {unmatched > 0 && onNavigate && (
              <div className="border-t border-line pt-3 mt-[14px]">
                <p className="text-ink-muted text-[12.5px] mb-2">{t('transactions.categorize_unmatched_hint')}</p>
                <button className="focus-inset text-brass-ink text-[13.5px] font-[550] inline-flex items-center gap-1.5"
                  onClick={() => { onClose(didCategorize); onNavigate('categories') }}>
                  {t('transactions.categorize_add_categories')}<Icon name="arrowRight" size={15} />
                </button>
              </div>
            )}
          </div>
        )
      )}

      {step === 'error' && (
        <div className="flex items-center gap-2.5 text-danger text-[13.5px]">
          <Icon name="alert" size={18} />{t('common.error')}
        </div>
      )}
    </Modal>
  )
}
