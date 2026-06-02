import { useState, useEffect, Fragment } from 'react'
import { useTranslation } from 'react-i18next'
import { api } from '../lib/api'
import type { CredentialsStatus } from '../lib/types'
import { Btn } from './ui'
import Icon from './Icon'

interface ConnectBankFlowProps {
  credentials: CredentialsStatus
}

type FlowStep = 'idle' | 'select_provider' | 'select_country' | 'select_institution' | 'connecting'

interface Institution {
  name: string
  id?: string
  logo?: string
  [key: string]: unknown
}

const COUNTRY_CODES = ['DE', 'AT', 'FI', 'SE', 'NO', 'DK', 'EE', 'LT', 'LV', 'NL', 'BE', 'FR', 'ES', 'IT', 'PT', 'GB', 'IE'] as const

export default function ConnectBankFlow({ credentials }: ConnectBankFlowProps) {
  const { t } = useTranslation()
  const [step, setStep] = useState<FlowStep>('idle')
  const [provider, setProvider] = useState('')
  const [country, setCountry] = useState('')
  const [institutions, setInstitutions] = useState<Institution[]>([])
  const [institutionSearch, setInstitutionSearch] = useState('')
  const [isLoadingInstitutions, setIsLoadingInstitutions] = useState(false)
  const [error, setError] = useState('')
  const [isConnecting, setIsConnecting] = useState(false)

  const hasEB = credentials.enable_banking.configured
  const hasGC = credentials.gocardless.configured
  const providerCount = (hasEB ? 1 : 0) + (hasGC ? 1 : 0)

  // Fetch institutions when country changes
  useEffect(() => {
    if (step !== 'select_institution' || !country || !provider) return
    setIsLoadingInstitutions(true)
    setError('')
    api(`/api/v1/institutions?provider=${provider}&country=${country}`)
      .then(async r => {
        if (r.ok) {
          setInstitutions(await r.json())
        } else {
          const data = await r.json()
          setError(data.error || t('common.error'))
        }
      })
      .catch(() => setError(t('common.error')))
      .finally(() => setIsLoadingInstitutions(false))
  }, [step, country, provider, t])

  const startFlow = () => {
    if (providerCount === 1) {
      setProvider(hasEB ? 'enable_banking' : 'gocardless')
      setStep('select_country')
    } else {
      setStep('select_provider')
    }
  }

  const selectProvider = (p: string) => {
    setProvider(p)
    setStep('select_country')
  }

  const selectCountry = (code: string) => {
    setCountry(code)
    setInstitutions([])
    setInstitutionSearch('')
    setStep('select_institution')
  }

  const selectInstitution = async (inst: Institution) => {
    setIsConnecting(true)
    setError('')
    try {
      const institutionId = (inst.id as string) || inst.name
      const institutionName = inst.name
      const r = await api('/api/v1/bank_connections', {
        method: 'POST',
        body: {
          provider,
          institution_id: institutionId,
          institution_name: institutionName,
          country_code: country,
        },
      })
      if (r.ok) {
        const data = await r.json()
        window.location.href = data.redirect_url
      } else {
        const data = await r.json()
        setError(data.error || data.errors?.[0] || t('common.error'))
        setIsConnecting(false)
      }
    } catch {
      setError(t('common.error'))
      setIsConnecting(false)
    }
  }

  const goBack = () => {
    if (step === 'select_institution') {
      setStep('select_country')
    } else if (step === 'select_country') {
      if (providerCount > 1) setStep('select_provider')
      else setStep('idle')
    } else if (step === 'select_provider') {
      setStep('idle')
    }
  }

  const filteredInstitutions = institutions.filter(inst =>
    (inst.name || '').toLowerCase().includes(institutionSearch.toLowerCase())
  )

  if (!hasEB && !hasGC) {
    return <p className="text-ink-muted text-[13px] italic">{t('settings.no_credentials')}</p>
  }

  if (step === 'idle') {
    return <Btn variant="primary" icon="plus" onClick={startFlow}>{t('settings.connect_bank')}</Btn>
  }

  // Redirecting state
  if (isConnecting) {
    return (
      <div className="text-center px-4 pt-[26px] pb-[30px]">
        <div className="w-12 h-12 mx-auto mb-[18px] grid place-items-center text-brass-ink">
          <Icon name="sync" size={30} className="spin" />
        </div>
        <div className="font-semibold text-base">{t('settings.redirecting_to')}</div>
        <div className="text-ink-muted text-[13px] mt-1.5 max-w-[360px] mx-auto leading-[1.55]">
          {t('settings.redirecting_note')}
        </div>
        <div className="inline-flex items-center gap-[7px] mt-[18px] text-xs text-income font-medium">
          <Icon name="shield" size={15} />{t('settings.redirect_secure')}
        </div>
      </div>
    )
  }

  // Stepper
  const steps = [t('settings.step_provider'), t('settings.step_country'), t('settings.step_institution')]
  const stepIndex = step === 'select_provider' ? 0 : step === 'select_country' ? 1 : 2

  return (
    <div>
      {/* Stepper */}
      <div className="flex items-center gap-2 mb-[18px]">
        {steps.map((s, i) => (
          <Fragment key={s}>
            <div className={'flex items-center gap-[7px] ' + (i <= stepIndex ? 'text-ink' : 'text-ink-faint')}>
              <span className={'mono w-5 h-5 rounded-full grid place-items-center text-[11px] border '
                + (i < stepIndex ? 'bg-brass text-on-ink border-transparent'
                  : i === stepIndex ? 'bg-brass-soft text-brass-ink border-transparent'
                  : 'bg-surface-2 text-ink-faint border-line')}>{i < stepIndex ? '✓' : i + 1}</span>
              <span className="text-[12.5px] font-[550]">{s}</span>
            </div>
            {i < steps.length - 1 && <div className="flex-1 h-px bg-line" />}
          </Fragment>
        ))}
      </div>

      <button className="focus-inset inline-flex items-center gap-1.5 text-ink-muted text-[12.5px] font-[550] mb-[14px]" onClick={goBack}>
        <Icon name="chevronLeft" size={15} />{t('common.back')}
      </button>

      {error && (
        <div className="flex items-center gap-2 text-[12.5px] text-danger font-medium mb-[14px]">
          <Icon name="alert" size={15} />{error}
        </div>
      )}

      {/* Select provider */}
      {step === 'select_provider' && (
        <div className="flex flex-col gap-2.5">
          {hasEB && (
            <button className="panel focus-inset text-left px-4 py-[14px] flex items-center justify-between gap-3" onClick={() => selectProvider('enable_banking')}>
              <div>
                <div className="font-semibold text-sm">{t('settings.enable_banking')}</div>
                <div className="text-ink-muted text-xs">{t('settings.enable_banking_description')}</div>
              </div>
              <Icon name="chevronRight" size={17} className="text-ink-faint" />
            </button>
          )}
          {hasGC && (
            <button className="panel focus-inset text-left px-4 py-[14px] flex items-center justify-between gap-3" onClick={() => selectProvider('gocardless')}>
              <div>
                <div className="font-semibold text-sm">{t('settings.gocardless')}</div>
                <div className="text-ink-muted text-xs">{t('settings.gocardless_description')}</div>
              </div>
              <Icon name="chevronRight" size={17} className="text-ink-faint" />
            </button>
          )}
        </div>
      )}

      {/* Select country */}
      {step === 'select_country' && (
        <div className="grid grid-cols-[repeat(auto-fill,minmax(160px,1fr))] gap-[9px]">
          {COUNTRY_CODES.map(code => (
            <button key={code} className="panel focus-inset text-left px-[15px] py-[13px] flex items-center gap-[11px]" onClick={() => selectCountry(code)}>
              <span className="mono text-xs font-semibold text-ink-muted w-[26px]">{code}</span>
              <span className="font-[550] text-[13.5px]">{t(`countries.${code}`)}</span>
            </button>
          ))}
        </div>
      )}

      {/* Select institution */}
      {step === 'select_institution' && (
        <div>
          <div className="search mb-3">
            <Icon name="search" size={17} />
            <input value={institutionSearch} onChange={e => setInstitutionSearch(e.target.value)} placeholder={t('settings.search_institutions')} aria-label={t('settings.search_institutions')} autoFocus />
          </div>
          <div className="flex flex-col gap-1.5 max-h-[320px] overflow-y-auto">
            {isLoadingInstitutions ? (
              <div className="text-ink-muted px-1 py-3 text-[13px]">{t('common.loading')}</div>
            ) : filteredInstitutions.length === 0 ? (
              <div className="text-ink-muted px-1 py-3 text-[13px]">{t('settings.no_institutions')}</div>
            ) : (
              filteredInstitutions.map((inst, i) => (
                <button key={inst.name + i} className="focus-inset flex items-center justify-between gap-3 px-[13px] py-[11px] rounded-md border border-line text-left hover:bg-surface-2" onClick={() => selectInstitution(inst)}>
                  <span className="flex items-center gap-[11px] min-w-0">
                    <span className="icon-tile icon-tile-sm text-[11px]">{inst.name.slice(0, 2).toUpperCase()}</span>
                    <span className="font-[550] text-[13.5px] overflow-hidden text-ellipsis whitespace-nowrap">{inst.name}</span>
                  </span>
                  <Icon name="external" size={15} className="text-ink-faint shrink-0" />
                </button>
              ))
            )}
          </div>
        </div>
      )}
    </div>
  )
}
