import { useState, useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { api } from '../lib/api'
import { formatAmount, formatDate, transactionDisplayName } from '../lib/format'
import type { Transaction, PaginationMeta, Account, Category } from '../lib/types'
import type { View } from '../components/SidebarNav'
import CategorizationModal from '../components/CategorizationModal'

export default function TransactionsPage({ onNavigate }: { onNavigate?: (view: View) => void }) {
  const { t } = useTranslation()
  const [transactions, setTransactions] = useState<Transaction[]>([])
  const [meta, setMeta] = useState<PaginationMeta>({ page: 1, per: 50, total: 0, total_pages: 0 })
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

  // LLM categorization
  const [llmConfigured, setLlmConfigured] = useState(false)
  const [showCategorizeModal, setShowCategorizeModal] = useState(false)

  // Expanded row
  const [expandedId, setExpandedId] = useState<number | null>(null)

  // Load dropdown data + LLM status once
  useEffect(() => {
    api('/api/v1/accounts').then(r => r.ok ? r.json() : []).then(setAccounts).catch(() => {})
    api('/api/v1/categories').then(r => r.ok ? r.json() : []).then(setCategories).catch(() => {})
    api('/api/v1/credentials').then(r => r.ok ? r.json() : null).then(data => {
      if (data?.llm?.configured) setLlmConfigured(true)
    }).catch(() => {})
  }, [])

  // Debounce search
  useEffect(() => {
    const timer = setTimeout(() => setDebouncedSearch(search), 300)
    return () => clearTimeout(timer)
  }, [search])

  // Reset page on filter change
  useEffect(() => { setPage(1) }, [debouncedSearch, accountId, categoryId, dateFrom, dateTo, uncategorized])

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
    params.set('page', String(page))
    params.set('per', '50')

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
  }, [debouncedSearch, accountId, categoryId, dateFrom, dateTo, uncategorized, page, retryKey])

  const hasMultipleAccounts = accounts.length > 1

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

  const hasFilters = search || accountId || categoryId || dateFrom || dateTo || uncategorized

  const clearFilters = () => {
    setSearch('')
    setAccountId('')
    setCategoryId('')
    setDateFrom('')
    setDateTo('')
    setUncategorized(false)
  }

  return (
    <div className="p-6 max-w-6xl mx-auto">
      {/* Page header — title + action */}
      <div className="flex items-center justify-between mb-4">
        <h2 className="text-2xl font-bold">{t('transactions.title')}</h2>
        {llmConfigured && (
          <button
            className="btn btn-primary text-xs px-3 py-2"
            onClick={() => setShowCategorizeModal(true)}
          >
            {t('transactions.categorize')}
          </button>
        )}
      </div>

      {/* Controls — search + filters as one unit */}
      <div className="controls-card">
        <input
          type="text"
          className="input controls-search"
          placeholder={t('transactions.search_placeholder')}
          value={search}
          onChange={e => setSearch(e.target.value)}
        />

        <div className="filter-bar">
          <select
            className="input"
            value={categoryId}
            onChange={e => setCategoryId(e.target.value)}
          >
            <option value="">{t('transactions.filter_category')}</option>
            {categories.map(c => (
              <option key={c.id} value={c.id}>{c.name}</option>
            ))}
          </select>
          {hasMultipleAccounts && (
            <select
              className="input"
              value={accountId}
              onChange={e => setAccountId(e.target.value)}
            >
              <option value="">{t('transactions.filter_account')}</option>
              {accounts.map(a => (
                <option key={a.id} value={a.id}>{a.name}</option>
              ))}
            </select>
          )}
          <input
            type="date"
            className="input"
            value={dateFrom}
            onChange={e => setDateFrom(e.target.value)}
            title={t('transactions.date_from')}
          />
          <input
            type="date"
            className="input"
            value={dateTo}
            onChange={e => setDateTo(e.target.value)}
            title={t('transactions.date_to')}
          />
          <button
            className={`btn text-xs ${uncategorized ? 'btn-primary' : 'btn-ghost'}`}
            onClick={() => setUncategorized(!uncategorized)}
          >
            {t('transactions.filter_uncategorized')}
          </button>
          {hasFilters && (
            <button
              className="link text-xs cursor-pointer ml-auto"
              onClick={clearFilters}
            >
              {t('transactions.clear_filters')}
            </button>
          )}
        </div>
      </div>

      {/* Transaction list */}
      <div className="card mt-3">
        {error ? (
          <div className="p-8">
            <div className="error-message flex items-center justify-between">
              <span>{t('common.load_error')}</span>
              <button className="btn-icon text-xs" onClick={() => setRetryKey(k => k + 1)}>{t('common.retry')}</button>
            </div>
          </div>
        ) : isLoading ? (
          <div className="p-8 text-center text-sm text-text-muted">
            {t('common.loading')}
          </div>
        ) : transactions.length === 0 ? (
          <div className="p-12 text-center">
            <p className="text-sm font-medium mb-2">
              {hasFilters ? t('transactions.no_results') : t('transactions.empty_title')}
            </p>
            <p className="text-sm text-text-muted mb-4">
              {hasFilters ? '' : t('transactions.empty_description')}
            </p>
            {hasFilters && (
              <button className="link text-sm cursor-pointer" onClick={clearFilters}>
                {t('transactions.clear_filters')}
              </button>
            )}
          </div>
        ) : (
          <>
            {transactions.map((tx) => {
              const amt = parseFloat(tx.amount)
              const isExpanded = expandedId === tx.id
              const counterpartyIban = amt < 0 ? tx.creditor_iban : tx.debtor_iban
              const showValueDate = tx.value_date && tx.value_date !== tx.booking_date

              return (
                <div key={tx.id}>
                  <div
                    className={`tx-row ${isExpanded ? 'tx-row-expanded' : ''}`}
                    onClick={() => setExpandedId(isExpanded ? null : tx.id)}
                  >
                    {/* Date */}
                    <span className="mono text-xs text-text-muted w-24 shrink-0 hidden sm:block">
                      {formatDate(tx.booking_date)}
                    </span>

                    {/* Name + meta */}
                    <div className="min-w-0 flex-1 mx-3">
                      <p className="font-medium text-sm truncate">
                        {transactionDisplayName(tx)}
                      </p>
                      <div className="flex items-center gap-2 mt-0.5 sm:hidden">
                        <span className="mono text-xs text-text-muted">
                          {formatDate(tx.booking_date)}
                        </span>
                      </div>
                    </div>

                    {/* Category badge */}
                    {tx.category ? (
                      <span className="badge badge-muted text-xs shrink-0 hidden md:inline-flex">
                        {tx.category.name}
                      </span>
                    ) : (
                      <span className="text-xs text-text-muted italic shrink-0 hidden md:inline-flex">
                        —
                      </span>
                    )}

                    {/* Amount */}
                    <p className={`mono font-semibold text-sm whitespace-nowrap ml-3 ${amt >= 0 ? 'amount-positive' : 'amount-negative'}`}>
                      {formatAmount(tx.amount, tx.currency)}
                    </p>
                  </div>

                  {/* Detail panel */}
                  <div className={`tx-detail ${isExpanded ? 'tx-detail-open' : ''}`}>
                    <div className="tx-detail-grid">
                      {tx.remittance && (
                        <>
                          <span className="tx-detail-label">{t('transactions.detail_remittance')}</span>
                          <span className="tx-detail-value">{tx.remittance}</span>
                        </>
                      )}
                      {tx.bank_transaction_code && (
                        <>
                          <span className="tx-detail-label">{t('transactions.detail_type')}</span>
                          <span className="tx-detail-value">{humanizeTransactionCode(tx.bank_transaction_code)}</span>
                        </>
                      )}
                      <span className="tx-detail-label">{t('transactions.detail_status')}</span>
                      <span className="tx-detail-value">
                        <span className={`status-dot ${tx.status === 'booked' ? 'status-dot-active' : 'status-dot-inactive'}`}>
                          {tx.status === 'booked' ? t('transactions.status_booked') : t('transactions.status_pending')}
                        </span>
                      </span>
                      {counterpartyIban && (
                        <>
                          <span className="tx-detail-label">{t('transactions.detail_iban')}</span>
                          <span className="tx-detail-value mono text-xs">{counterpartyIban}</span>
                        </>
                      )}
                      {showValueDate && (
                        <>
                          <span className="tx-detail-label">{t('transactions.detail_value_date')}</span>
                          <span className="tx-detail-value mono text-xs">{formatDate(tx.value_date!)}</span>
                        </>
                      )}
                      {hasMultipleAccounts && tx.account_name && (
                        <>
                          <span className="tx-detail-label">{t('transactions.detail_account')}</span>
                          <span className="tx-detail-value">{tx.account_name}</span>
                        </>
                      )}
                    </div>
                  </div>
                </div>
              )
            })}
          </>
        )}
      </div>

      {/* Pagination — stark prev/next blocks */}
      {meta.total_pages > 1 && (
        <div className="flex items-center justify-between mt-0">
          <button
            className="btn btn-ghost text-sm"
            style={{ padding: '0.625rem 1rem' }}
            disabled={page <= 1}
            onClick={() => setPage(p => p - 1)}
          >
            {t('transactions.prev')}
          </button>
          <span className="mono text-xs text-text-muted">
            {t('transactions.page_of', { page, total: meta.total_pages })}
          </span>
          <button
            className="btn btn-ghost text-sm"
            style={{ padding: '0.625rem 1rem' }}
            disabled={page >= meta.total_pages}
            onClick={() => setPage(p => p + 1)}
          >
            {t('transactions.next')}
          </button>
        </div>
      )}
      {showCategorizeModal && (
        <CategorizationModal onNavigate={onNavigate} onClose={(didCategorize) => {
          setShowCategorizeModal(false)
          if (didCategorize) setRetryKey(k => k + 1)
        }} />
      )}
    </div>
  )
}
