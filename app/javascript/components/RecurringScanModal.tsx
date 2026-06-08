import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { api } from '../lib/api'
import { Modal, Btn, Eyebrow } from './ui'
import Icon from './Icon'

interface Props {
  onClose: (didDetect: boolean) => void
}

type Step = 'confirm' | 'running' | 'done' | 'error'

interface DetectResult {
  detected: number
  active: number
  ended: number
}

export default function RecurringScanModal({ onClose }: Props) {
  const { t } = useTranslation()
  const [step, setStep] = useState<Step>('confirm')
  const [results, setResults] = useState<DetectResult | null>(null)

  const handleDetect = async () => {
    setStep('running')
    try {
      const r = await api('/api/v1/recurring/detect', { method: 'POST' })
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

  const didDetect = results !== null
  const dismissable = step !== 'running'
  const handleClose = () => { if (dismissable) onClose(didDetect) }

  let footer: React.ReactNode = null
  if (step === 'confirm') {
    footer = (
      <>
        <Btn variant="ghost" onClick={() => onClose(false)}>{t('common.cancel')}</Btn>
        <Btn variant="primary" icon="scan" onClick={handleDetect}>{t('recurring.scan')}</Btn>
      </>
    )
  } else if (step === 'running') {
    footer = (
      <Btn variant="primary" disabled>
        <Icon name="sync" size={15} className="spin" />{t('recurring.scanning')}
      </Btn>
    )
  } else if (step === 'done' || step === 'error') {
    footer = <Btn variant="ghost" onClick={() => onClose(didDetect)}>{t('recurring.scan_close')}</Btn>
  }

  return (
    <Modal title={t('recurring.scan_title')} icon="recurring" onClose={dismissable ? handleClose : undefined} footer={footer} closeLabel={t('common.close')}>
      {step === 'confirm' && (
        <>
          <p className="text-ink-muted text-[13.5px] leading-[1.6]">{t('recurring.scan_confirm')}</p>
          <div className="mt-4 flex items-center gap-[9px] px-[13px] py-2.5 bg-surface-2 border border-line rounded-md">
            <Icon name="shield" size={17} className="text-income shrink-0" />
            <span className="text-[12.5px] font-medium">{t('recurring.scan_privacy')}</span>
          </div>
        </>
      )}

      {step === 'running' && (
        <div className="flex items-center gap-[11px] py-1">
          <Icon name="sync" size={18} className="spin text-brass-ink" />
          <div>
            <div className="font-semibold text-sm">{t('recurring.scanning')}</div>
            <div className="text-ink-muted text-[12.5px] mt-px">{t('recurring.scan_wait')}</div>
          </div>
        </div>
      )}

      {step === 'done' && results && (
        <div className="pb-1.5">
          <div className="flex items-center gap-[11px] mb-[14px]">
            <span className="icon-tile icon-tile-ok"><Icon name="check" size={19} /></span>
            <div className="font-semibold text-[14.5px]">{t('recurring.scan_done')}</div>
          </div>
          <div className="flex gap-6">
            <div>
              <div className="mono amt-pos text-2xl font-medium">{results.detected}</div>
              <Eyebrow className="mt-[3px]">{t('recurring.scan_detected')}</Eyebrow>
            </div>
            <div>
              <div className="mono text-2xl font-medium">{results.active}</div>
              <Eyebrow className="mt-[3px]">{t('recurring.scan_active')}</Eyebrow>
            </div>
            {results.ended > 0 && (
              <div>
                <div className="mono text-ink-faint text-2xl font-medium">{results.ended}</div>
                <Eyebrow className="mt-[3px]">{t('recurring.scan_ended')}</Eyebrow>
              </div>
            )}
          </div>
        </div>
      )}

      {step === 'error' && (
        <div className="flex items-center gap-2.5 text-danger text-[13.5px]">
          <Icon name="alert" size={18} />{t('common.error')}
        </div>
      )}
    </Modal>
  )
}
