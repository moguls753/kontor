import { useState, useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { api } from '../lib/api'

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

  const toggleAll = () => {
    if (selected.size === suggestions.length) {
      setSelected(new Set())
    } else {
      setSelected(new Set(suggestions))
    }
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

  return (
    <div className="modal-backdrop" onClick={() => dismissable && onClose(didCreate)}>
      <div
        className={`modal-dialog ${step === 'loading' || step === 'creating' ? 'modal-dialog-processing' : ''}`}
        style={{ maxWidth: '30rem' }}
        onClick={e => e.stopPropagation()}
      >
        {step === 'loading' && (
          <div className="flex items-center gap-3">
            <span className="spinner" style={{ color: 'var(--color-accent)' }} />
            <div>
              <p className="text-sm font-semibold">{t('categories.suggesting')}</p>
              <p className="text-xs text-text-muted mt-0.5">{t('categories.suggest_wait')}</p>
            </div>
          </div>
        )}

        {step === 'review' && (
          <>
            <h3 className="text-base font-bold mb-1">{t('categories.suggest_title')}</h3>
            <p className="text-sm text-text-muted mb-4">{t('categories.suggest_description')}</p>

            <div className="border-2 border-border mb-4 max-h-64 overflow-y-auto">
              <label className="flex items-center gap-3 px-3 py-2 border-b-2 border-border cursor-pointer hover:bg-surface-sunken">
                <input
                  type="checkbox"
                  checked={selected.size === suggestions.length}
                  onChange={toggleAll}
                  style={{ accentColor: 'var(--color-accent)' }}
                />
                <span className="text-xs font-bold uppercase tracking-wider text-text-muted">
                  {t('categories.suggest_select_all')} ({selected.size}/{suggestions.length})
                </span>
              </label>
              {suggestions.map(name => (
                <label
                  key={name}
                  className="flex items-center gap-3 px-3 py-2 border-b-2 border-border last:border-b-0 cursor-pointer hover:bg-surface-sunken"
                >
                  <input
                    type="checkbox"
                    checked={selected.has(name)}
                    onChange={() => toggleSelection(name)}
                    style={{ accentColor: 'var(--color-accent)' }}
                  />
                  <span className="text-sm">{name}</span>
                </label>
              ))}
            </div>

            <div className="flex items-center gap-3">
              <button
                className="btn btn-primary text-sm px-4 py-2"
                onClick={handleCreate}
                disabled={selected.size === 0}
              >
                {t('common.save')} ({selected.size})
              </button>
              <button className="btn btn-ghost text-sm px-4 py-2" onClick={() => onClose(false)}>
                {t('common.cancel')}
              </button>
            </div>
          </>
        )}

        {step === 'creating' && (
          <div className="flex items-center gap-3">
            <span className="spinner" style={{ color: 'var(--color-accent)' }} />
            <p className="text-sm font-semibold">{t('categories.suggest_creating')}</p>
          </div>
        )}

        {step === 'done' && (
          <>
            {suggestions.length === 0 ? (
              <p className="text-sm text-text-muted">{t('categories.suggest_none')}</p>
            ) : (
              <>
                <h3 className="text-base font-bold mb-2">{t('categories.suggest_title')}</h3>
                <p className="text-sm text-text-muted mb-4">
                  {t('categories.suggest_done', { count: createdCount })}
                </p>
              </>
            )}
            <button className="btn btn-ghost text-sm px-4 py-2" onClick={() => onClose(didCreate)}>
              {t('transactions.categorize_close')}
            </button>
          </>
        )}

        {step === 'error' && (
          <>
            <div className="error-message mb-4">{t('common.error')}</div>
            <button className="btn btn-ghost text-sm px-4 py-2" onClick={() => onClose(false)}>
              {t('transactions.categorize_close')}
            </button>
          </>
        )}
      </div>
    </div>
  )
}
