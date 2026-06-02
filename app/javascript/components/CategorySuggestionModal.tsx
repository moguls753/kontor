import { useState, useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { api } from '../lib/api'
import { Modal, Btn, catColor, hueFor } from './ui'
import Icon from './Icon'

interface Props {
  onClose: (didCreate: boolean) => void
}

type Step = 'loading' | 'review' | 'creating' | 'done' | 'error'

export default function CategorySuggestionModal({ onClose }: Props) {
  const { t, i18n } = useTranslation()
  const [step, setStep] = useState<Step>('loading')
  const [suggestions, setSuggestions] = useState<string[]>([])
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [createdCount, setCreatedCount] = useState(0)

  useEffect(() => {
    api('/api/v1/categories/suggest', { method: 'POST', body: { locale: i18n.language } })
      .then(async r => {
        if (r.ok) {
          const data = await r.json()
          const names: string[] = data.suggestions || []
          setSuggestions(names)
          setSelected(new Set(names))
          setStep(names.length > 0 ? 'review' : 'done')
        } else {
          setStep('error')
        }
      })
      .catch(() => setStep('error'))
  }, [])

  const toggleSelection = (name: string) => {
    setSelected(prev => {
      const next = new Set(prev)
      if (next.has(name)) next.delete(name)
      else next.add(name)
      return next
    })
  }

  const handleCreate = async () => {
    setStep('creating')
    let created = 0
    for (const name of selected) {
      try {
        const r = await api('/api/v1/categories', {
          method: 'POST',
          body: { category: { name } },
        })
        if (r.ok) created++
      } catch {
        // skip individual failures
      }
    }
    setCreatedCount(created)
    setStep('done')
  }

  const didCreate = createdCount > 0
  const dismissable = step !== 'loading' && step !== 'creating'
  const handleClose = () => { if (dismissable) onClose(didCreate) }

  let footer: React.ReactNode = null
  if (step === 'review') {
    footer = (
      <>
        <Btn variant="ghost" onClick={() => onClose(false)}>{t('common.cancel')}</Btn>
        <Btn variant="primary" icon="plus" disabled={selected.size === 0} onClick={handleCreate}>
          {t('common.save')} ({selected.size})
        </Btn>
      </>
    )
  } else if (step === 'creating') {
    footer = <Btn variant="primary" disabled><Icon name="sync" size={15} className="spin" />{t('categories.suggest_creating')}</Btn>
  } else if (step === 'done' || step === 'error') {
    footer = <Btn variant="ghost" onClick={() => onClose(didCreate)}>{t('transactions.categorize_close')}</Btn>
  }

  return (
    <Modal title={t('categories.suggest_title')} icon="scan" onClose={dismissable ? handleClose : undefined} footer={footer} closeLabel={t('common.close')}>
      {step === 'loading' && (
        <div className="flex items-center gap-[11px]">
          <Icon name="sync" size={18} className="spin text-brass-ink" />
          <div>
            <div className="font-semibold text-sm">{t('categories.suggesting')}</div>
            <div className="text-ink-muted text-[12.5px] mt-px">{t('categories.suggest_wait')}</div>
          </div>
        </div>
      )}

      {step === 'review' && (
        <>
          <p className="text-ink-muted text-[13.5px] leading-[1.6]">{t('categories.suggest_description')}</p>
          <div className="flex flex-wrap gap-[9px] mt-4 pb-1">
            {suggestions.map(name => {
              const on = selected.has(name)
              return (
                <button key={name} onClick={() => toggleSelection(name)}
                  className={'inline-flex items-center gap-2 px-[13px] py-2 rounded-md border font-[550] text-[13px] '
                    + (on ? 'border-brass bg-brass-soft text-ink' : 'border-line-strong bg-surface text-ink-muted')}>
                  <span className="w-[3px] h-3.5 rounded-[2px]" style={{ background: catColor(hueFor(name)) }} />
                  {name}
                  {on && <Icon name="check" size={14} className="text-brass-ink" />}
                </button>
              )
            })}
          </div>
        </>
      )}

      {step === 'creating' && (
        <div className="flex items-center gap-[11px]">
          <Icon name="sync" size={18} className="spin text-brass-ink" />
          <span className="font-semibold text-sm">{t('categories.suggest_creating')}</span>
        </div>
      )}

      {step === 'done' && (
        suggestions.length === 0 ? (
          <p className="text-ink-muted text-[13.5px]">{t('categories.suggest_none')}</p>
        ) : (
          <div className="flex items-center gap-[11px]">
            <span className="icon-tile icon-tile-ok"><Icon name="check" size={19} /></span>
            <span className="text-[13.5px]">{t('categories.suggest_done', { count: createdCount })}</span>
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
