import { useState, useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { api } from '../lib/api'
import LanguageSwitcher from '../components/LanguageSwitcher'
import CredentialForm from '../components/CredentialForm'
import ConnectBankFlow from '../components/ConnectBankFlow'
import TradeRepublicPairingModal from '../components/TradeRepublicPairingModal'
import EasybankPairingModal from '../components/EasybankPairingModal'
import { Btn, Eyebrow } from '../components/ui'
import Icon from '../components/Icon'
import type { IconName } from '../components/Icon'
import type { CredentialsStatus } from '../lib/types'

export default function SettingsPage() {
  const { t } = useTranslation()
  const [credentials, setCredentials] = useState<CredentialsStatus | null>(null)
  const [isLoading, setIsLoading] = useState(true)
  const [error, setError] = useState(false)
  const [expandedProvider, setExpandedProvider] = useState<string | null>(null)
  const [showTrModal, setShowTrModal] = useState(false)
  const [trNotice, setTrNotice] = useState('')
  const [showEasybankModal, setShowEasybankModal] = useState(false)
  const [easybankNotice, setEasybankNotice] = useState('')
  // PayPal manual sync — a single SYNCHRONOUS, blocking request (no polling). The
  // user approves the out-of-band device push on their phone while it blocks.
  const [paypalSyncing, setPaypalSyncing] = useState(false)
  const [paypalNotice, setPaypalNotice] = useState('')
  const [paypalError, setPaypalError] = useState('')

  const fetchCredentials = async () => {
    setIsLoading(true)
    setError(false)
    try {
      const r = await api('/api/v1/credentials')
      if (r.ok) setCredentials(await r.json())
      else setError(true)
    } catch {
      setError(true)
    } finally {
      setIsLoading(false)
    }
  }

  useEffect(() => { fetchCredentials() }, [])

  const toggleProvider = (p: string) => setExpandedProvider(prev => prev === p ? null : p)

  // Manual PayPal sync. Ensures the (authorized) connection exists, then fires
  // ONE synchronous sync_paypal that BLOCKS while the user approves the app push
  // on their phone. No polling — the single request returns the final result.
  const handlePaypalSync = async () => {
    setPaypalSyncing(true); setPaypalNotice(''); setPaypalError('')
    try {
      // create_paypal is idempotent (find_or_initialize_by) — safe to call each sync.
      const cr = await api('/api/v1/bank_connections', { method: 'POST', body: { provider: 'paypal' } })
      const conn = await cr.json().catch(() => ({}))
      if (!cr.ok || !conn.id) { setPaypalError(t('paypal.sync_error')); return }

      const r = await api(`/api/v1/bank_connections/${conn.id}/sync_paypal`, { method: 'POST' })
      if (r.ok) { setPaypalNotice(t('paypal.synced_notice')); return }

      const data = await r.json().catch(() => ({}))
      const msg = data.error === 'rate_limited'
        ? t('paypal.rate_limited', { hours: Math.max(1, Math.ceil((data.retry_in ?? 3600) / 3600)) })
        : data.error === 'push_timeout' || data.error === 'captcha_blocked' ? t('paypal.try_again_later')
        : data.error === 'login_failed' ? t('paypal.login_failed')
        : data.error === 'scraper_unavailable' ? t('paypal.scraper_unavailable')
        : (data.message || t('paypal.sync_error'))
      setPaypalError(msg)
    } catch {
      setPaypalError(t('paypal.sync_error'))
    } finally {
      setPaypalSyncing(false)
    }
  }

  return (
    <div className="page max-w-[760px]">
      <div className="page-head"><h1 className="page-title">{t('settings.title')}</h1></div>

      <div className="grid gap-4">
        <Eyebrow>{t('settings.group_general')}</Eyebrow>

        {/* Language */}
        <SettingsPanel icon="settings" title={t('settings.language')} desc={t('settings.language_description')}>
          <LanguageSwitcher />
        </SettingsPanel>

        {isLoading ? (
          <div className="panel panel-pad text-ink-muted text-[13.5px]">{t('common.loading')}</div>
        ) : error ? (
          <div className="panel panel-pad flex items-center justify-between gap-3">
            <span className="text-danger text-[13.5px]">{t('common.load_error')}</span>
            <Btn variant="secondary" size="sm" icon="sync" onClick={fetchCredentials}>{t('common.retry')}</Btn>
          </div>
        ) : credentials ? (
          <>
            {/* LLM */}
            <SettingsPanel icon="scan" title={t('settings.llm')} desc={t('settings.llm_description')}
              status={credentials.llm.configured}
              statusLabel={credentials.llm.configured ? t('settings.configured') : t('settings.not_configured')}
              action={
                <Btn variant="ghost" size="sm" onClick={() => toggleProvider('llm')}>
                  {credentials.llm.configured ? t('settings.update_credentials') : t('settings.configure')}
                </Btn>
              }>
              {credentials.llm.configured && (
                <p className={'text-ink-faint mono text-[11.5px] ' + (expandedProvider === 'llm' ? 'mb-[14px]' : 'mb-0')}>
                  {credentials.llm.base_url} — {credentials.llm.llm_model}
                </p>
              )}
              {expandedProvider === 'llm' && (
                <CredentialForm
                  provider="llm"
                  isConfigured={credentials.llm.configured}
                  onSaved={() => { fetchCredentials(); setExpandedProvider(null) }}
                  initialValues={credentials.llm.configured ? { base_url: credentials.llm.base_url ?? '', llm_model: credentials.llm.llm_model ?? '' } : undefined}
                />
              )}
            </SettingsPanel>

            <Eyebrow className="mt-2">{t('settings.group_open_banking')}</Eyebrow>

            {/* Enable Banking */}
            <SettingsPanel icon="bank" title={t('settings.enable_banking')} desc={t('settings.enable_banking_description')}
              status={credentials.enable_banking.configured}
              statusLabel={credentials.enable_banking.configured ? t('settings.configured') : t('settings.not_configured')}
              action={
                <Btn variant="ghost" size="sm" onClick={() => toggleProvider('enable_banking')}>
                  {credentials.enable_banking.configured ? t('settings.update_credentials') : t('settings.configure')}
                </Btn>
              }>
              {expandedProvider === 'enable_banking' && (
                <CredentialForm
                  provider="enable_banking"
                  isConfigured={credentials.enable_banking.configured}
                  onSaved={() => { fetchCredentials(); setExpandedProvider(null) }}
                  initialValues={credentials.enable_banking.configured ? { app_id: credentials.enable_banking.app_id ?? '' } : undefined}
                />
              )}
            </SettingsPanel>

            {/* GoCardless */}
            <SettingsPanel icon="link" title={t('settings.gocardless')} desc={t('settings.gocardless_description')}
              status={credentials.gocardless.configured}
              statusLabel={credentials.gocardless.configured ? t('settings.configured') : t('settings.not_configured')}
              action={
                <Btn variant="ghost" size="sm" onClick={() => toggleProvider('gocardless')}>
                  {credentials.gocardless.configured ? t('settings.update_credentials') : t('settings.configure')}
                </Btn>
              }>
              {expandedProvider === 'gocardless' && (
                <CredentialForm
                  provider="gocardless"
                  isConfigured={credentials.gocardless.configured}
                  onSaved={() => { fetchCredentials(); setExpandedProvider(null) }}
                />
              )}
            </SettingsPanel>

            {/* Connect a bank (Open Banking only) */}
            <SettingsPanel icon="plus" title={t('settings.connect_bank')} desc={t('settings.connect_bank_description')}>
              <ConnectBankFlow credentials={credentials} />
            </SettingsPanel>

            <Eyebrow className="mt-2">{t('settings.group_direct')}</Eyebrow>

            {/* Trade Republic */}
            <SettingsPanel icon="shield" title={t('settings.trade_republic')} desc={t('settings.trade_republic_description')}
              status={credentials.trade_republic.configured}
              statusLabel={credentials.trade_republic.configured ? t('settings.configured') : t('settings.not_configured')}
              action={
                <div className="flex items-center gap-2">
                  {credentials.trade_republic.configured && (
                    <Btn variant="primary" size="sm" icon="link" onClick={() => { setTrNotice(''); setShowTrModal(true) }}>
                      {t('settings.tr_connect')}
                    </Btn>
                  )}
                  <Btn variant="ghost" size="sm" onClick={() => toggleProvider('trade_republic')}>
                    {credentials.trade_republic.configured ? t('settings.update_credentials') : t('settings.configure')}
                  </Btn>
                </div>
              }>
              {credentials.trade_republic.configured && credentials.trade_republic.phone_number_masked && (
                <p className={'text-ink-faint mono text-[11.5px] ' + (expandedProvider === 'trade_republic' || trNotice ? 'mb-[14px]' : 'mb-0')}>
                  {credentials.trade_republic.phone_number_masked}
                </p>
              )}
              {trNotice && (
                <div className="flex items-center gap-2 text-income text-[12.5px] font-medium mb-[14px]">
                  <Icon name="check" size={15} />{trNotice}
                </div>
              )}
              {expandedProvider === 'trade_republic' && (
                <CredentialForm
                  provider="trade_republic"
                  isConfigured={credentials.trade_republic.configured}
                  onSaved={() => { fetchCredentials(); setExpandedProvider(null) }}
                />
              )}
            </SettingsPanel>

            {/* easybank Kreditkarte */}
            <SettingsPanel icon="shield" title={t('settings.easybank')} desc={t('settings.easybank_description')}
              status={credentials.easybank.configured}
              statusLabel={credentials.easybank.configured ? t('settings.configured') : t('settings.not_configured')}
              action={
                <div className="flex items-center gap-2">
                  {credentials.easybank.configured && (
                    <Btn variant="primary" size="sm" icon="link" onClick={() => { setEasybankNotice(''); setShowEasybankModal(true) }}>
                      {t('settings.easybank_connect')}
                    </Btn>
                  )}
                  <Btn variant="ghost" size="sm" onClick={() => toggleProvider('easybank')}>
                    {credentials.easybank.configured ? t('settings.update_credentials') : t('settings.configure')}
                  </Btn>
                </div>
              }>
              {credentials.easybank.configured && credentials.easybank.username_masked && (
                <p className={'text-ink-faint mono text-[11.5px] ' + (expandedProvider === 'easybank' || easybankNotice ? 'mb-[14px]' : 'mb-0')}>
                  {credentials.easybank.username_masked}
                </p>
              )}
              {easybankNotice && (
                <div className="flex items-center gap-2 text-income text-[12.5px] font-medium mb-[14px]">
                  <Icon name="check" size={15} />{easybankNotice}
                </div>
              )}
              {expandedProvider === 'easybank' && (
                <CredentialForm
                  provider="easybank"
                  isConfigured={credentials.easybank.configured}
                  onSaved={() => { fetchCredentials(); setExpandedProvider(null) }}
                />
              )}
            </SettingsPanel>

            {/* PayPal — manual sync only */}
            <SettingsPanel icon="shield" title={t('settings.paypal')} desc={t('settings.paypal_description')}
              status={credentials.paypal.configured}
              statusLabel={credentials.paypal.configured ? t('settings.configured') : t('settings.not_configured')}
              action={
                <div className="flex items-center gap-2">
                  {credentials.paypal.configured && (
                    <Btn variant="primary" size="sm" icon="sync" onClick={handlePaypalSync} disabled={paypalSyncing}>
                      {paypalSyncing ? t('paypal.syncing') : t('paypal.sync')}
                    </Btn>
                  )}
                  <Btn variant="ghost" size="sm" onClick={() => toggleProvider('paypal')}>
                    {credentials.paypal.configured ? t('settings.update_credentials') : t('settings.configure')}
                  </Btn>
                </div>
              }>
              {credentials.paypal.configured && credentials.paypal.username_masked && (
                <p className={'text-ink-faint mono text-[11.5px] ' + (expandedProvider === 'paypal' || paypalSyncing || paypalNotice || paypalError ? 'mb-[14px]' : 'mb-0')}>
                  {credentials.paypal.username_masked}
                </p>
              )}
              {paypalSyncing && (
                <div className="flex items-center gap-2 text-ink-muted text-[12.5px] font-[550] mb-[14px]">
                  <Icon name="sync" size={15} className="spin text-brass-ink" />{t('paypal.approve_on_phone')}
                </div>
              )}
              {!paypalSyncing && paypalNotice && (
                <div className="flex items-center gap-2 text-income text-[12.5px] font-medium mb-[14px]">
                  <Icon name="check" size={15} />{paypalNotice}
                </div>
              )}
              {!paypalSyncing && paypalError && (
                <div className="flex items-start gap-2 text-danger text-[12.5px] font-medium mb-[14px]">
                  <Icon name="alert" size={15} className="shrink-0 mt-px" />{paypalError}
                </div>
              )}
              {expandedProvider === 'paypal' && (
                <CredentialForm
                  provider="paypal"
                  isConfigured={credentials.paypal.configured}
                  onSaved={() => { fetchCredentials(); setExpandedProvider(null) }}
                />
              )}
            </SettingsPanel>
          </>
        ) : null}
      </div>

      {showTrModal && (
        <TradeRepublicPairingModal
          title={t('trade_republic.pair_title')}
          initiate={() => api('/api/v1/bank_connections', { method: 'POST', body: { provider: 'trade_republic' } })}
          onConnected={() => { setShowTrModal(false); setTrNotice(t('trade_republic.connected_notice')) }}
          onClose={() => setShowTrModal(false)}
        />
      )}

      {showEasybankModal && (
        <EasybankPairingModal
          title={t('easybank.pair_title')}
          initiate={() => api('/api/v1/bank_connections', { method: 'POST', body: { provider: 'easybank' } })}
          onConnected={() => { setShowEasybankModal(false); setEasybankNotice(t('easybank.connected_notice')) }}
          onClose={() => setShowEasybankModal(false)}
        />
      )}
    </div>
  )
}

interface SettingsPanelProps {
  icon: IconName
  title: string
  desc?: string
  status?: boolean
  statusLabel?: string
  action?: React.ReactNode
  children?: React.ReactNode
}

function SettingsPanel({ icon, title, desc, status, statusLabel, action, children }: SettingsPanelProps) {
  return (
    <div className="panel">
      <div className="panel-head">
        <div className="flex gap-3 items-center min-w-0">
          <span className="icon-tile">
            <Icon name={icon} size={17} />
          </span>
          <div className="min-w-0">
            <div className="flex items-center gap-2.5">
              <span className="section-title">{title}</span>
              {statusLabel != null && (
                <span className={'badge ' + (status ? 'badge-ok' : 'badge-neutral')}>
                  {status && <span className="dot" />}{statusLabel}
                </span>
              )}
            </div>
            {desc && <div className="text-ink-faint text-xs mt-px">{desc}</div>}
          </div>
        </div>
        {action && <div className="shrink-0">{action}</div>}
      </div>
      {children && <div className="panel-pad">{children}</div>}
    </div>
  )
}
