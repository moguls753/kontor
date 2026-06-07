import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { api } from '../lib/api'
import { Btn } from './ui'
import Icon from './Icon'

interface CredentialFormProps {
  provider: 'enable_banking' | 'gocardless' | 'llm' | 'trade_republic' | 'easybank' | 'paypal'
  isConfigured: boolean
  onSaved: () => void
  initialValues?: Record<string, string>
}

export default function CredentialForm({ provider, isConfigured, onSaved, initialValues }: CredentialFormProps) {
  const { t } = useTranslation()
  const [isSaving, setIsSaving] = useState(false)
  const [error, setError] = useState('')

  // Enable Banking fields
  const [appId, setAppId] = useState(initialValues?.app_id ?? '')
  const [privateKey, setPrivateKey] = useState('')

  // GoCardless fields
  const [secretId, setSecretId] = useState('')
  const [secretKey, setSecretKey] = useState('')

  // Trade Republic fields
  const [phone, setPhone] = useState('')
  const [pin, setPin] = useState('')

  // easybank fields
  const [easybankUsername, setEasybankUsername] = useState('')
  const [easybankPassword, setEasybankPassword] = useState('')

  // PayPal fields
  const [paypalUsername, setPaypalUsername] = useState('')
  const [paypalPassword, setPaypalPassword] = useState('')

  // LLM fields
  const [baseUrl, setBaseUrl] = useState(initialValues?.base_url ?? '')
  const [apiKey, setApiKey] = useState('')
  const [llmModel, setLlmModel] = useState(initialValues?.llm_model ?? '')

  // Test connection
  const [isTesting, setIsTesting] = useState(false)
  const [testResult, setTestResult] = useState<{ status: 'ok' | 'error'; message: string } | null>(null)

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setIsSaving(true)
    setError('')
    setTestResult(null)

    const method = isConfigured ? 'PATCH' : 'POST'
    let credentials: Record<string, string>
    if (provider === 'enable_banking') {
      credentials = { app_id: appId, private_key_pem: privateKey }
    } else if (provider === 'gocardless') {
      credentials = { secret_id: secretId, secret_key: secretKey }
    } else if (provider === 'trade_republic') {
      credentials = { phone_number: phone, pin }
    } else if (provider === 'easybank') {
      credentials = { username: easybankUsername, password: easybankPassword }
    } else if (provider === 'paypal') {
      credentials = { username: paypalUsername, password: paypalPassword }
    } else {
      credentials = { base_url: baseUrl, llm_model: llmModel, api_key: apiKey || '' }
    }

    try {
      const r = await api('/api/v1/credentials', {
        method,
        body: { provider, credentials },
      })
      if (r.ok) {
        onSaved()
      } else {
        const data = await r.json()
        setError(data.errors?.[0] || data.error || t('common.error'))
      }
    } catch {
      setError(t('common.error'))
    } finally {
      setIsSaving(false)
    }
  }

  const handleTest = async () => {
    setIsTesting(true)
    setTestResult(null)
    try {
      const r = await api('/api/v1/credentials/test', { method: 'POST' })
      const data = await r.json()
      setTestResult(data)
    } catch {
      setTestResult({ status: 'error', message: t('common.error') })
    } finally {
      setIsTesting(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="grid gap-[15px]">
      {provider === 'enable_banking' ? (
        <>
          <label className="block">
            <span className="field-label">{t('settings.app_id')}</span>
            <input className="field field-mono" value={appId} onChange={e => setAppId(e.target.value)} placeholder="app_••••" required />
          </label>
          <label className="block">
            <span className="field-label">{t('settings.private_key')}</span>
            <textarea className="field field-mono min-h-32 text-xs" value={privateKey} onChange={e => setPrivateKey(e.target.value)} placeholder="-----BEGIN PRIVATE KEY-----" required />
          </label>
        </>
      ) : provider === 'gocardless' ? (
        <div className="settings-2col grid grid-cols-2 gap-[15px]">
          <label className="block">
            <span className="field-label">{t('settings.secret_id')}</span>
            <input className="field field-mono" value={secretId} onChange={e => setSecretId(e.target.value)} placeholder="••••••••" required />
          </label>
          <label className="block">
            <span className="field-label">{t('settings.secret_key')}</span>
            <input className="field field-mono" type="password" value={secretKey} onChange={e => setSecretKey(e.target.value)} placeholder="••••••••" required />
          </label>
        </div>
      ) : provider === 'trade_republic' ? (
        <div className="settings-2col grid grid-cols-[1fr_140px] gap-[15px]">
          <label className="block">
            <span className="field-label">{t('settings.tr_phone')}</span>
            <input className="field field-mono" value={phone} onChange={e => setPhone(e.target.value)} placeholder={t('settings.tr_phone_placeholder')} autoComplete="off" required />
          </label>
          <label className="block">
            <span className="field-label">{t('settings.tr_pin')}</span>
            <input className="field field-mono" type="password" inputMode="numeric" value={pin} onChange={e => setPin(e.target.value)} placeholder="••••" autoComplete="off" required />
          </label>
        </div>
      ) : provider === 'easybank' ? (
        <div className="settings-2col grid grid-cols-2 gap-[15px]">
          <label className="block">
            <span className="field-label">{t('settings.easybank_username')}</span>
            <input className="field field-mono" value={easybankUsername} onChange={e => setEasybankUsername(e.target.value)} placeholder={t('settings.easybank_username_placeholder')} autoComplete="off" required />
          </label>
          <label className="block">
            <span className="field-label">{t('settings.easybank_password')}</span>
            <input className="field field-mono" type="password" value={easybankPassword} onChange={e => setEasybankPassword(e.target.value)} placeholder="••••••••" autoComplete="off" required />
          </label>
        </div>
      ) : provider === 'paypal' ? (
        <div className="settings-2col grid grid-cols-2 gap-[15px]">
          <label className="block">
            <span className="field-label">{t('settings.paypal_username')}</span>
            <input className="field field-mono" value={paypalUsername} onChange={e => setPaypalUsername(e.target.value)} placeholder={t('settings.paypal_username_placeholder')} autoComplete="off" required />
          </label>
          <label className="block">
            <span className="field-label">{t('settings.paypal_password')}</span>
            <input className="field field-mono" type="password" value={paypalPassword} onChange={e => setPaypalPassword(e.target.value)} placeholder="••••••••" autoComplete="off" required />
          </label>
        </div>
      ) : (
        <>
          <label className="block">
            <span className="field-label">{t('settings.llm_endpoint')}</span>
            <input className="field field-mono" value={baseUrl} onChange={e => setBaseUrl(e.target.value)} placeholder="https://api.openai.com/v1" required />
          </label>
          <div className="settings-2col grid grid-cols-[1fr_200px] gap-[15px]">
            <label className="block">
              <span className="field-label">{t('settings.llm_api_key')}</span>
              <input className="field field-mono" type="password" value={apiKey} onChange={e => setApiKey(e.target.value)} placeholder={t('settings.llm_api_key_placeholder')} />
            </label>
            <label className="block">
              <span className="field-label">{t('settings.llm_model')}</span>
              <input className="field field-mono" value={llmModel} onChange={e => setLlmModel(e.target.value)} placeholder="gpt-4o-mini" required />
            </label>
          </div>
        </>
      )}

      {error && (
        <div className="flex items-center gap-2 text-[12.5px] text-danger font-medium">
          <Icon name="alert" size={15} />{error}
        </div>
      )}

      <div className="flex items-center gap-2.5">
        {/* Live test-connection status (LLM only) */}
        {provider === 'llm' && (
          <div className="mr-auto min-h-5 flex items-center">
            {isTesting && (
              <span className="flex items-center gap-[7px] text-[12.5px] text-ink-muted font-[550]">
                <Icon name="sync" size={15} className="spin" />{t('settings.llm_testing')}
              </span>
            )}
            {!isTesting && testResult?.status === 'ok' && (
              <span className="flex items-center gap-[7px] text-[12.5px] text-income font-[550]">
                <Icon name="check" size={15} />{t('settings.llm_test_ok')}
              </span>
            )}
            {!isTesting && testResult?.status === 'error' && (
              <span className="flex items-center gap-[7px] text-[12.5px] text-danger font-[550]">
                <Icon name="alert" size={15} />{testResult.message}
              </span>
            )}
          </div>
        )}

        {provider === 'llm' && isConfigured && (
          <Btn variant="secondary" onClick={handleTest} disabled={isTesting}>
            {isTesting ? t('settings.llm_testing') : t('settings.llm_test')}
          </Btn>
        )}
        <Btn variant="primary" type="submit" disabled={isSaving}>
          {isSaving ? t('settings.saving') : t('settings.save_credentials')}
        </Btn>
      </div>
    </form>
  )
}
