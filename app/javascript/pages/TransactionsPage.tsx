import { useState, useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { api } from '../lib/api'
import { useScope, withScope } from '../lib/scope'
import { formatDate, formatDateLong, transactionDisplayName, maskIban } from '../lib/format'
import type { Transaction, PaginationMeta, Account, Category } from '../lib/types'
import RecalculateButton from '../components/RecalculateButton'
import Icon from '../components/Icon'
import { Amount, Btn, CategoryChip, CpAvatar, Empty, Eyebrow, Select } from '../components/ui'

const LEDGER_COLS = 'minmax(0,1fr) 172px 152px 116px 148px 36px'
const PER = 50

export default function TransactionsPage() {
  const { t } = useTranslation()
  const { scope } = useScope()
  const [transactions, setTransactions] = useState<Transaction[]>([])
  const [meta, setMeta] = useState<PaginationMeta>({ page: 1, per: PER, total: 0, total_pages: 0 })
  const [isLoading, setIsLoading] = useState(true)
  const [error, setError] = useState(false)
  const [retryKey, setRetryKey] = useState(0)

  // Filters
  const [search, setSearch] = useState('')
  const [debouncedSearch, setDebouncedSearch] = useState('')
  const [accountId, setAccountId] = useState('')
  const [categoryId, setCategoryId] = useState('')
  const [dateFrom, setDateFrom] = useState('')
  const [dateTo, setDateTo] = useState('')
  const [uncategorized, setUncategorized] = useState(false)
  const [page, setPage] = useState(1)

  // Dropdown data
  const [accounts, setAccounts] = useState<Account[]>([])
  const [categories, setCategories] = useState<Category[]>([])

  // Expanded row
  const [expandedId, setExpandedId] = useState<number | null>(null)

  // Load dropdown data once
  useEffect(() => {
    api('/api/v1/accounts').then(r => r.ok ? r.json() : []).then(setAccounts).catch(() => {})
    api('/api/v1/categories').then(r => r.ok ? r.json() : []).then(setCategories).catch(() => {})
  }, [])

  // Debounce search
  useEffect(() => {
    const timer = setTimeout(() => setDebouncedSearch(search), 300)
    return () => clearTimeout(timer)
  }, [search])

  // Reset page on filter change
  useEffect(() => { setPage(1) }, [debouncedSearch, accountId, categoryId, dateFrom, dateTo, uncategorized, scope])

  // Fetch transactions
  useEffect(() => {
    const controller = new AbortController()
    const params = new URLSearchParams()
    if (debouncedSearch) params.set('search', debouncedSearch)
    if (accountId) params.set('account_id', accountId)
    if (categoryId) params.set('category_id', categoryId)
    if (dateFrom) params.set('from', dateFrom)
    if (dateTo) params.set('to', dateTo)
    if (uncategorized) params.set('uncategorized', 'true')
    withScope(params, scope)
    params.set('page', String(page))
    params.set('per', String(PER))

    setIsLoading(true)
    setError(false)
    fetch(`/api/v1/transactions?${params}`, {
      headers: { 'Accept': 'application/json' },
      signal: controller.signal,
    })
      .then(async r => {
        if (r.ok) {
          const data = await r.json()
          setTransactions(data.transactions)
          setMeta(data.meta)
        } else {
          setError(true)
        }
      })
      .catch(e => {
        if (e.name !== 'AbortError') setError(true)
      })
      .finally(() => setIsLoading(false))

    return () => controller.abort()
  }, [debouncedSearch, accountId, categoryId, dateFrom, dateTo, uncategorized, page, retryKey, scope])

  // In "privat" the shared (Gemeinschafts-) accounts are out of scope, so listing
  // them in the filter would only yield empty results — drop them from the options.
  const visibleAccounts = accounts.filter(a => scope !== 'privat' || !a.shared)
  const hasMultipleAccounts = visibleAccounts.length > 1

  // If the selected account is hidden by the active scope, clear it so the list
  // doesn't silently show nothing.
  useEffect(() => {
    if (accountId && !visibleAccounts.some(a => String(a.id) === accountId)) setAccountId('')
  }, [accountId, visibleAccounts])

  const humanizeTransactionCode = (code: string | null): string | null => {
    if (!code) return null
    const map: Record<string, string> = {
      DIRECT_DEBIT: t('transactions.type_direct_debit'),
      SEPA_CREDIT_TRANSFER: t('transactions.type_sepa_credit_transfer'),
      CARD_PAYMENT: t('transactions.type_card_payment'),
      STANDING_ORDER: t('transactions.type_standing_order'),
    }
    return map[code] || code.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase())
  }

  const hasFilters = !!(search || accountId || categoryId || dateFrom || dateTo || uncategorized)

  const clearFilters = () => {
    setSearch('')
    setAccountId('')
    setCategoryId('')
    setDateFrom('')
    setDateTo('')
    setUncategorized(false)
  }

  const fromIdx = meta.total === 0 ? 0 : (meta.page - 1) * meta.per + 1
  const toIdx = Math.min(meta.page * meta.per, meta.total)

  return (
    <div className="page">
      <div className="page-head">
        <h1 className="page-title">{t('transactions.title')}</h1>
        <RecalculateButton onStarted={() => setRetryKey(k => k + 1)} />
      </div>

      {/* Filter bar */}
      <div className="flex gap-2.5 flex-wrap items-center mb-4">
        <div className="search flex-[1_1_280px] min-w-[220px]">
          <Icon name="search" size={17} />
          <input value={search} onChange={e => setSearch(e.target.value)} placeholder={t('transactions.search_placeholder')} aria-label={t('transactions.search_placeholder')} />
        </div>
        <Select value={categoryId} onChange={e => setCategoryId(e.target.value)} ariaLabel={t('transactions.filter_category')}>
          <option value="">{t('transactions.filter_category')}</option>
          {categories.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}
        </Select>
        {hasMultipleAccounts && (
          <Select value={accountId} onChange={e => setAccountId(e.target.value)} ariaLabel={t('transactions.filter_account')}>
            <option value="">{t('transactions.filter_account')}</option>
            {visibleAccounts.map(a => <option key={a.id} value={a.id}>{a.name}</option>)}
          </Select>
        )}
        <input type="date" className="field w-auto min-w-[150px]" value={dateFrom} onChange={e => setDateFrom(e.target.value)} title={t('transactions.date_from')} />
        <input type="date" className="field w-auto min-w-[150px]" value={dateTo} onChange={e => setDateTo(e.target.value)} title={t('transactions.date_to')} />
        <button
          onClick={() => setUncategorized(v => !v)}
          className={'btn btn-sm ' + (uncategorized ? 'btn-secondary border-brass text-brass-ink bg-brass-soft' : 'btn-ghost')}
        >
          <span className={'w-[7px] h-[7px] rounded-[2px] ' + (uncategorized ? 'bg-brass' : 'bg-ink-faint')} />
          {t('transactions.filter_uncategorized')}
        </button>
        {hasFilters && <Btn variant="ghost" size="sm" icon="close" onClick={clearFilters}>{t('transactions.clear_filters')}</Btn>}
      </div>

      {/* Ledger */}
      <div className="panel overflow-hidden">
        <div className="ledger-head eyebrow" style={{ ['--ledger-cols' as string]: LEDGER_COLS }}>
          <div>{t('transactions.col_counterparty')}</div>
          <div className="lg-mid">{t('transactions.col_category')}</div>
          <div className="lg-mid">{t('transactions.col_account')}</div>
          <div className="lg-mid">{t('transactions.detail_booked')}</div>
          <div className="text-right">{t('transactions.col_amount')}</div>
          <div />
        </div>

        {error ? (
          <div className="panel-pad flex items-center justify-between gap-3">
            <span className="text-danger text-[13.5px]">{t('common.load_error')}</span>
            <Btn variant="secondary" size="sm" icon="sync" onClick={() => setRetryKey(k => k + 1)}>{t('common.retry')}</Btn>
          </div>
        ) : isLoading ? (
          <div className="text-ink-muted text-[13.5px] text-center px-5 py-10">{t('common.loading')}</div>
        ) : transactions.length === 0 ? (
          <Empty icon="search" title={hasFilters ? t('transactions.no_results') : t('transactions.empty_title')}
            body={hasFilters ? undefined : t('transactions.empty_description')}>
            {hasFilters && <Btn variant="secondary" size="sm" onClick={clearFilters}>{t('transactions.clear_filters')}</Btn>}
          </Empty>
        ) : (
          transactions.map(tx => (
            <Row
              key={tx.id}
              tx={tx}
              t={t}
              open={expandedId === tx.id}
              onToggle={() => setExpandedId(o => o === tx.id ? null : tx.id)}
              hasMultipleAccounts={hasMultipleAccounts}
              humanizeTransactionCode={humanizeTransactionCode}
            />
          ))
        )}

        {!error && !isLoading && meta.total > 0 && (
          <div className="panel-foot flex items-center justify-between">
            <span className="text-ink-muted text-[12.5px]">
              {t('transactions.showing', { from: fromIdx, to: toIdx, total: meta.total })}
            </span>
            {meta.total_pages > 1 && (
              <div className="flex gap-2 items-center">
                <Btn variant="secondary" size="sm" icon="chevronLeft" onClick={() => setPage(p => Math.max(1, p - 1))} disabled={page <= 1}>{t('transactions.prev')}</Btn>
                <span className="mono text-ink-muted text-[12.5px] min-w-[44px] text-center">{meta.page}/{meta.total_pages}</span>
                <Btn variant="secondary" size="sm" iconRight="chevronRight" onClick={() => setPage(p => Math.min(meta.total_pages, p + 1))} disabled={page >= meta.total_pages}>{t('transactions.next')}</Btn>
              </div>
            )}
          </div>
        )}
      </div>

    </div>
  )
}

interface RowProps {
  tx: Transaction
  t: (key: string, opts?: Record<string, unknown>) => string
  open: boolean
  onToggle: () => void
  hasMultipleAccounts: boolean
  humanizeTransactionCode: (code: string | null) => string | null
}

function Row({ tx, t, open, onToggle, hasMultipleAccounts, humanizeTransactionCode }: RowProps) {
  const num = parseFloat(tx.amount)
  const name = transactionDisplayName(tx)
  const counterpartyIban = num < 0 ? tx.creditor_iban : tx.debtor_iban
  const showValueDate = tx.value_date && tx.value_date !== tx.booking_date

  return (
    <div className="ledger-row-wrap">
      <button className={'ledger-row focus-inset' + (open ? ' open' : '')}
        style={{ ['--ledger-cols' as string]: LEDGER_COLS }} onClick={onToggle} aria-expanded={open}>
        <div className="ledger-cp">
          <CpAvatar name={name} sign={num > 0 ? 1 : -1} />
          <div className="min-w-0">
            <div className="cp-name">{name}</div>
            {tx.remittance && <div className="cp-remit">{tx.remittance}</div>}
            <div className="row-meta-mobile">
              <CategoryChip name={tx.category?.name ?? null} uncategorisedLabel={t('transactions.uncategorized_chip')} />
              <span className="text-ink-faint mono text-[11px]">{formatDate(tx.booking_date)}</span>
            </div>
          </div>
        </div>
        <div className="lg-mid"><CategoryChip name={tx.category?.name ?? null} uncategorisedLabel={t('transactions.uncategorized_chip')} /></div>
        <div className="lg-mid text-ink-faint text-[12.5px] overflow-hidden text-ellipsis whitespace-nowrap">{tx.account_name}</div>
        <div className="lg-mid mono text-ink-faint text-[12.5px]">{formatDate(tx.booking_date)}</div>
        <div className="ledger-amt"><Amount value={tx.amount} currency={tx.currency} className="text-[14.5px]" /></div>
        <span className="ledger-expand"><Icon name="chevronRight" size={16} className="chev" /></span>
      </button>
      {open && (
        <div className="ledger-detail">
          {tx.remittance && (
            <div className="detail-field">
              <Eyebrow>{t('transactions.detail_remittance')}</Eyebrow>
              <div className="val font-mono text-[12.5px] leading-normal">{tx.remittance}</div>
            </div>
          )}
          <div className="detail-field">
            <Eyebrow>{t('transactions.detail_booked')}</Eyebrow>
            <div className="val">{formatDateLong(tx.booking_date)}</div>
          </div>
          {tx.bank_transaction_code && (
            <div className="detail-field">
              <Eyebrow>{t('transactions.detail_type')}</Eyebrow>
              <div className="val">{humanizeTransactionCode(tx.bank_transaction_code)}</div>
            </div>
          )}
          <div className="detail-field">
            <Eyebrow>{t('transactions.detail_status')}</Eyebrow>
            <div className="val flex items-center gap-[7px]">
              <span className={'w-[7px] h-[7px] rounded-[2px] ' + (tx.status === 'booked' ? 'bg-income' : 'bg-ink-faint')} />
              {tx.status === 'booked' ? t('transactions.status_booked') : t('transactions.status_pending')}
            </div>
          </div>
          {counterpartyIban && (
            <div className="detail-field">
              <Eyebrow>{t('transactions.detail_iban')}</Eyebrow>
              <div className="val mono text-[12.5px]">{maskIban(counterpartyIban)}</div>
            </div>
          )}
          {showValueDate && (
            <div className="detail-field">
              <Eyebrow>{t('transactions.detail_value_date')}</Eyebrow>
              <div className="val mono text-[12.5px]">{formatDate(tx.value_date!)}</div>
            </div>
          )}
          {hasMultipleAccounts && tx.account_name && (
            <div className="detail-field">
              <Eyebrow>{t('transactions.detail_account')}</Eyebrow>
              <div className="val">{tx.account_name}</div>
            </div>
          )}
        </div>
      )}
    </div>
  )
}
