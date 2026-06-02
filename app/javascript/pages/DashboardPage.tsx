import { useState, useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { api } from '../lib/api'
import { formatAmount, formatDate, transactionDisplayName, maskIban } from '../lib/format'
import type { DashboardData, DashboardAccount } from '../lib/types'
import type { View } from '../components/SidebarNav'
import { Amount, Btn, CpAvatar, Empty, Eyebrow, balance } from '../components/ui'
import Icon from '../components/Icon'

interface DashboardPageProps {
  onNavigate?: (view: View) => void
}

const MAX_VISIBLE_ACCOUNTS = 6

export default function DashboardPage({ onNavigate }: DashboardPageProps) {
  const { t } = useTranslation()
  const [data, setData] = useState<DashboardData | null>(null)
  const [isLoading, setIsLoading] = useState(true)
  const [error, setError] = useState(false)

  const fetchDashboard = async () => {
    setIsLoading(true)
    setError(false)
    try {
      const response = await api('/api/v1/dashboard')
      if (response.ok) setData(await response.json())
      else setError(true)
    } catch {
      setError(true)
    } finally {
      setIsLoading(false)
    }
  }

  useEffect(() => { fetchDashboard() }, [])

  if (isLoading) {
    return (
      <div className="page">
        <div className="text-ink-muted text-[13.5px]">{t('common.loading')}</div>
      </div>
    )
  }

  if (error) {
    return (
      <div className="page">
        <div className="panel panel-pad flex items-center justify-between gap-3">
          <span className="text-danger text-[13.5px]">{t('common.load_error')}</span>
          <Btn variant="secondary" size="sm" icon="sync" onClick={fetchDashboard}>{t('common.retry')}</Btn>
        </div>
      </div>
    )
  }

  const hasData = data && data.transaction_count > 0

  // First-run empty state
  if (!hasData) {
    return (
      <div className="page">
        <div className="page-head"><h1 className="page-title">{t('nav.dashboard')}</h1></div>
        <div className="panel">
          <Empty icon="bank" title={t('dashboard.no_transactions')} body={t('dashboard.no_transactions_description')}>
            <Btn variant="primary" icon="plus" onClick={() => onNavigate?.('settings')}>{t('dashboard.connect_bank')}</Btn>
          </Empty>
        </div>
      </div>
    )
  }

  const balanceChange = parseFloat(data!.balance_change)
  const visibleAccounts = data!.accounts.slice(0, MAX_VISIBLE_ACCOUNTS)
  const hiddenAccountCount = Math.max(0, data!.accounts.length - MAX_VISIBLE_ACCOUNTS)
  const accountsWithBalance = data!.accounts.filter(a => a.balance_amount != null).length
  const recent = data!.recent_transactions.slice(0, 5)

  const incomeNum = parseFloat(data!.income)
  const expenseNum = Math.abs(parseFloat(data!.expenses))
  const flowMax = Math.max(incomeNum, expenseNum, 1)

  return (
    <div className="page">
      <div className="page-head">
        <div>
          <div className="text-ink-muted text-[13px]">{t('dashboard.greeting')}</div>
          <h1 className="page-title mt-0.5">{t('nav.dashboard')}</h1>
        </div>
      </div>

      {/* Hero + month flows */}
      <div className="dash-hero-grid grid grid-cols-[minmax(0,1.55fr)_minmax(0,1fr)] gap-[18px] mb-[18px]">
        <div className="panel panel-pad flex flex-col justify-between gap-[22px]">
          <div>
            <Eyebrow>{t('dashboard.total_balance')}</Eyebrow>
            <div className="mt-2.5">
              <span className="amt amt-neg font-medium tracking-[-0.02em] text-[clamp(38px,5vw,54px)]">
                {balance(data!.total_balance).text}
              </span>
            </div>
            <div className="text-ink-muted text-[13px] mt-1.5">
              {t('dashboard.across_accounts', { count: accountsWithBalance })}
            </div>
            <BalanceChangeLabel change={balanceChange} percent={data!.balance_change_percent} t={t} />
          </div>

          {/* Month income/expense mini-bars (real data) */}
          <div className="flex items-end justify-between gap-5">
            <svg width="100%" viewBox="0 0 200 64" role="img" aria-label="Income and expenses this month" className="max-w-[260px]">
              <line x1="0" y1="56" x2="200" y2="56" stroke="var(--line)" strokeWidth="1" />
              <rect x="40" y={56 - (incomeNum / flowMax) * 50} width="34" height={(incomeNum / flowMax) * 50} rx="2" fill="var(--income)" opacity="0.95" />
              <rect x="116" y={56 - (expenseNum / flowMax) * 50} width="34" height={(expenseNum / flowMax) * 50} rx="2" fill="var(--ink)" opacity="0.55" />
            </svg>
            <div className="flex gap-4 pb-1">
              <span className="text-ink-muted flex items-center gap-1.5 text-[11.5px]">
                <span className="w-2 h-2 rounded-[2px] bg-income" />{t('dashboard.flow_in')}</span>
              <span className="text-ink-muted flex items-center gap-1.5 text-[11.5px]">
                <span className="w-2 h-2 rounded-[2px] bg-ink opacity-[0.55]" />{t('dashboard.flow_out')}</span>
            </div>
          </div>
        </div>

        <div className="panel flex flex-col">
          <StatTile label={t('dashboard.income_label')}>
            <Amount value={data!.income} className="text-[22px]" />
          </StatTile>
          <StatTile label={t('dashboard.expenses_label')}>
            <Amount value={data!.expenses} className="text-[22px]" />
          </StatTile>
          <div className="px-[18px] py-[15px] flex items-center justify-between gap-3">
            <div>
              <Eyebrow>{t('dashboard.uncategorized')}</Eyebrow>
              <div className={'mono text-[22px] font-medium mt-1.5 ' + (data!.uncategorized_count ? 'text-brass-ink' : 'text-ink')}>
                {data!.uncategorized_count}
              </div>
            </div>
            {data!.uncategorized_count > 0 && (
              <Btn variant="secondary" size="sm" iconRight="arrowRight" onClick={() => onNavigate?.('transactions')}>{t('dashboard.review')}</Btn>
            )}
          </div>
        </div>
      </div>

      {/* Accounts */}
      {visibleAccounts.length > 0 && (
        <>
          <div className="flex items-center justify-between mt-1.5 mb-[13px] mx-0.5">
            <h2 className="section-title">{t('dashboard.accounts')}</h2>
            <Btn variant="ghost" size="sm" iconRight="arrowRight" onClick={() => onNavigate?.('accounts')}>{t('dashboard.view_all')}</Btn>
          </div>
          <div className="grid grid-cols-[repeat(auto-fill,minmax(220px,1fr))] gap-[14px] mb-[30px]">
            {visibleAccounts.map(a => <AccountCard key={a.id} acct={a} onOpen={() => onNavigate?.('accounts')} />)}
          </div>
          {hiddenAccountCount > 0 && (
            <div className="-mt-[18px] mb-[30px] text-right">
              <Btn variant="ghost" size="sm" iconRight="arrowRight" onClick={() => onNavigate?.('accounts')}>
                {t('dashboard.more_accounts', { count: hiddenAccountCount })}
              </Btn>
            </div>
          )}
        </>
      )}

      {/* Recent activity */}
      <div className="flex items-center justify-between mt-1.5 mb-[13px] mx-0.5">
        <h2 className="section-title">{t('dashboard.recent_title')}</h2>
        <Btn variant="ghost" size="sm" iconRight="arrowRight" onClick={() => onNavigate?.('transactions')}>{t('dashboard.view_all')}</Btn>
      </div>
      <div className="panel overflow-hidden">
        {recent.map((tx, i) => {
          const num = parseFloat(tx.amount)
          const name = transactionDisplayName(tx)
          return (
            <div key={tx.id} className={'grid grid-cols-[1fr_auto] gap-4 items-center px-[18px] py-3' + (i < recent.length - 1 ? ' border-b border-line' : '')}>
              <div className="flex items-center gap-3 min-w-0">
                <CpAvatar name={name} sign={num > 0 ? 1 : -1} />
                <div className="min-w-0">
                  <div className="font-[550] text-[13.5px] overflow-hidden text-ellipsis whitespace-nowrap">{name}</div>
                  <div className="text-ink-faint text-[11.5px] flex gap-2">
                    <span className="mono">{formatDate(tx.booking_date)}</span>
                    <span>·</span>
                    <span className="overflow-hidden text-ellipsis whitespace-nowrap">{tx.account_name}</span>
                    {tx.category ? (<><span>·</span><span>{tx.category.name}</span></>) : (<><span>·</span><span className="text-ink-faint">{t('dashboard.uncategorized')}</span></>)}
                  </div>
                </div>
              </div>
              <Amount value={tx.amount} currency={tx.currency} className="text-[14.5px]" />
            </div>
          )
        })}
      </div>
    </div>
  )
}

function StatTile({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="px-[18px] py-[15px] border-b border-line">
      <Eyebrow>{label}</Eyebrow>
      <div className="mt-[7px] flex items-baseline gap-2">{children}</div>
    </div>
  )
}

function AccountCard({ acct, onOpen }: { acct: DashboardAccount; onOpen: () => void }) {
  return (
    <button className="panel focus-inset text-left p-0 transition-colors hover:border-line-strong" onClick={onOpen}>
      <div className="px-[17px] py-[15px] flex flex-col gap-[14px] h-full">
        <div className="flex items-center gap-2.5">
          <span className="icon-tile icon-tile-sm">
            <Icon name="coin" size={16} />
          </span>
          <div className="min-w-0 flex-1">
            <div className="font-semibold text-[13.5px] overflow-hidden text-ellipsis whitespace-nowrap">{acct.name}</div>
            <div className="text-ink-faint mono text-[11px]">{maskIban(acct.iban)}</div>
          </div>
        </div>
        <div>
          <Amount value={acct.balance_amount} currency={acct.currency} signed={false} className="text-[26px]" />
        </div>
      </div>
    </button>
  )
}

function BalanceChangeLabel({ change, percent, t }: {
  change: number
  percent: number | null
  t: (key: string, opts?: Record<string, unknown>) => string
}) {
  if (change === 0) {
    return <div className="text-ink-muted text-[12.5px] mt-2">{t('dashboard.no_change')}</div>
  }
  const isPositive = change > 0
  const sign = isPositive ? '+' : '−'
  const text = percent !== null
    ? `${sign}${Math.abs(percent)}% ${t('dashboard.this_month')}`
    : `${sign}${formatAmount(Math.abs(change))} ${t('dashboard.this_month')}`
  return <div className={'mono text-[12.5px] mt-2 font-[550] ' + (isPositive ? 'text-income' : 'text-danger')}>{text}</div>
}
