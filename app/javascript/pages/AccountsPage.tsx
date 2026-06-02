import { useState, useEffect, useRef, useCallback } from 'react'
import { useTranslation } from 'react-i18next'
import { api } from '../lib/api'
import { formatRelativeTime, maskIban } from '../lib/format'
import type { BankConnection, BankConnectionAccount } from '../lib/types'
import type { View } from '../components/SidebarNav'
import { Amount, Btn, StatusBadge, Empty } from '../components/ui'
import Icon from '../components/Icon'

interface AccountsPageProps {
  onNavigate?: (view: View) => void
}

export default function AccountsPage({ onNavigate }: AccountsPageProps) {
  const { t } = useTranslation()
  const [connections, setConnections] = useState<BankConnection[]>([])
  const [isLoading, setIsLoading] = useState(true)
  const [error, setError] = useState(false)
  const [syncingIds, setSyncingIds] = useState<Set<number>>(new Set())
  const [editingId, setEditingId] = useState<number | null>(null)
  const [editValue, setEditValue] = useState('')
  const editRef = useRef<HTMLInputElement>(null)
  const blurCancelledRef = useRef(false)
  const pollTimers = useRef<Map<number, ReturnType<typeof setInterval>>>(new Map())

  const fetchConnections = async () => {
    setIsLoading(true)
    setError(false)
    try {
      const r = await api('/api/v1/bank_connections')
      if (r.ok) setConnections(await r.json())
      else setError(true)
    } catch {
      setError(true)
    } finally {
      setIsLoading(false)
    }
  }

  useEffect(() => { fetchConnections() }, [])

  // Clean up poll timers on unmount
  useEffect(() => {
    const timers = pollTimers.current
    return () => { timers.forEach(t => clearInterval(t)) }
  }, [])

  // Focus the rename input when editing starts
  useEffect(() => {
    if (editingId !== null) {
      editRef.current?.focus()
      editRef.current?.select()
    }
  }, [editingId])

  const stopPolling = useCallback((id: number) => {
    const timer = pollTimers.current.get(id)
    if (timer) { clearInterval(timer); pollTimers.current.delete(id) }
    setSyncingIds(prev => { const next = new Set(prev); next.delete(id); return next })
  }, [])

  const handleSync = async (id: number) => {
    const beforeSync = connections.find(c => c.id === id)?.last_synced_at
    setSyncingIds(prev => new Set(prev).add(id))
    try {
      const r = await api(`/api/v1/bank_connections/${id}/sync`, { method: 'POST' })
      if (!r.ok) { stopPolling(id); return }

      const startedAt = Date.now()
      const timer = setInterval(async () => {
        try {
          const pr = await api('/api/v1/bank_connections')
          if (pr.ok) {
            const fresh: BankConnection[] = await pr.json()
            setConnections(fresh)
            const updated = fresh.find(c => c.id === id)
            if (updated?.last_synced_at !== beforeSync) { stopPolling(id); return }
          }
        } catch { /* polling failure is not critical */ }
        if (Date.now() - startedAt > 30000) stopPolling(id)
      }, 3000)
      pollTimers.current.set(id, timer)
    } catch {
      stopPolling(id)
    }
  }

  const handleReconnect = async (id: number) => {
    try {
      const r = await api(`/api/v1/bank_connections/${id}/reconnect`, { method: 'POST' })
      if (r.ok) {
        const data = await r.json()
        if (data.redirect_url) { window.location.href = data.redirect_url; return }
      }
      setError(true)
    } catch {
      setError(true)
    }
  }

  const handleDelete = async (id: number) => {
    if (!window.confirm(t('accounts.delete_confirm'))) return
    try {
      const r = await api(`/api/v1/bank_connections/${id}`, { method: 'DELETE' })
      if (r.ok || r.status === 204) {
        setConnections(prev => prev.filter(c => c.id !== id))
      }
    } catch {
      // silent
    }
  }

  const startRename = (acctId: number, currentName: string) => {
    blurCancelledRef.current = false
    setEditingId(acctId)
    setEditValue(currentName)
  }

  const cancelRename = () => {
    blurCancelledRef.current = true
    setEditingId(null)
    setEditValue('')
  }

  const saveRename = async () => {
    if (blurCancelledRef.current || editingId === null) return
    blurCancelledRef.current = true
    const trimmed = editValue.trim()
    if (!trimmed) { cancelRename(); return }

    const savedId = editingId
    setEditingId(null)
    setEditValue('')

    setConnections(prev => prev.map(bc => ({
      ...bc,
      accounts: bc.accounts.map(a =>
        a.id === savedId ? { ...a, name: trimmed } : a
      )
    })))

    try {
      await api(`/api/v1/accounts/${savedId}`, {
        method: 'PATCH',
        body: { name: trimmed }
      })
    } catch {
      fetchConnections()
    }
  }

  if (isLoading) {
    return (
      <div className="page">
        <div className="page-head"><h1 className="page-title">{t('accounts.title')}</h1></div>
        <div className="text-ink-muted text-[13.5px]">{t('common.loading')}</div>
      </div>
    )
  }

  if (error) {
    return (
      <div className="page">
        <div className="page-head"><h1 className="page-title">{t('accounts.title')}</h1></div>
        <div className="panel panel-pad flex items-center justify-between gap-3">
          <span className="text-danger text-[13.5px]">{t('common.load_error')}</span>
          <Btn variant="secondary" size="sm" icon="sync" onClick={fetchConnections}>{t('common.retry')}</Btn>
        </div>
      </div>
    )
  }

  return (
    <div className="page">
      <div className="page-head">
        <div>
          <h1 className="page-title">{t('accounts.title')}</h1>
          <div className="text-ink-muted text-[13px] mt-0.5">{t('accounts.subtitle')}</div>
        </div>
        <Btn variant="primary" icon="plus" onClick={() => onNavigate?.('settings')}>{t('accounts.connect_bank')}</Btn>
      </div>

      {connections.length === 0 ? (
        <div className="panel">
          <Empty icon="bank" title={t('accounts.empty_title')} body={t('accounts.empty_description')}>
            <Btn variant="primary" icon="plus" onClick={() => onNavigate?.('settings')}>{t('accounts.connect_bank')}</Btn>
          </Empty>
        </div>
      ) : (
        <div className="grid gap-4">
          {connections.map(bc => (
            <ConnectionCard
              key={bc.id}
              bc={bc}
              t={t}
              syncing={syncingIds.has(bc.id)}
              onSync={() => handleSync(bc.id)}
              onReconnect={() => handleReconnect(bc.id)}
              onDelete={() => handleDelete(bc.id)}
              editingId={editingId}
              editValue={editValue}
              editRef={editRef}
              setEditValue={setEditValue}
              startRename={startRename}
              saveRename={saveRename}
              cancelRename={cancelRename}
            />
          ))}
        </div>
      )}
    </div>
  )
}

interface ConnectionCardProps {
  bc: BankConnection
  t: (key: string, opts?: Record<string, unknown>) => string
  syncing: boolean
  onSync: () => void
  onReconnect: () => void
  onDelete: () => void
  editingId: number | null
  editValue: string
  editRef: React.RefObject<HTMLInputElement | null>
  setEditValue: (v: string) => void
  startRename: (id: number, name: string) => void
  saveRename: () => void
  cancelRename: () => void
}

function ConnectionCard({ bc, t, syncing, onSync, onReconnect, onDelete, editingId, editValue, editRef, setEditValue, startRename, saveRename, cancelRename }: ConnectionCardProps) {
  const instName = bc.institution_name || bc.institution_id
  const short = (instName || '??').slice(0, 2).toUpperCase()
  const count = bc.accounts.length

  return (
    <div className="panel">
      <div className="panel-head">
        <div className="flex items-center gap-3 min-w-0">
          <span className="icon-tile icon-tile-lg">{short}</span>
          <div className="min-w-0">
            <div className="font-semibold text-[14.5px] overflow-hidden text-ellipsis whitespace-nowrap">{instName}</div>
            <div className="text-ink-faint text-[11.5px]">
              {count === 1 ? t('accounts.account_one', { count }) : t('accounts.account_other', { count })}
              {bc.status === 'authorized' && bc.last_synced_at && <> · {t('accounts.synced')} {formatRelativeTime(bc.last_synced_at)}</>}
            </div>
          </div>
        </div>
        <div className="flex items-center gap-2 shrink-0">
          <StatusBadge status={bc.status} label={t(`accounts.status_${bc.status}`)} />
          {(bc.status === 'authorized' || bc.status === 'pending') ? (
            <button className="ibtn btn-sm w-8 h-8" onClick={onSync}
              title={syncing ? t('accounts.syncing') : t('accounts.sync')} disabled={syncing || bc.status !== 'authorized'}>
              <Icon name="sync" size={16} className={syncing ? 'spin' : ''} />
            </button>
          ) : (
            <Btn variant="secondary" size="sm" icon="link" onClick={onReconnect}>{t('accounts.reconnect')}</Btn>
          )}
          <button className="ibtn btn-sm w-8 h-8" title={t('accounts.delete_connection')} onClick={onDelete}>
            <Icon name="trash" size={15} />
          </button>
        </div>
      </div>

      {bc.error_message && (
        <div className="flex gap-2.5 items-start px-[18px] py-[11px] bg-danger-soft border-b border-line">
          <Icon name="alert" size={16} className="text-danger shrink-0 mt-px" />
          <span className="text-[12.5px] text-danger font-medium">{bc.error_message}</span>
        </div>
      )}

      {bc.accounts.length === 0 ? (
        <div className="text-ink-muted px-[18px] py-4 text-[12.5px]">{t('accounts.no_accounts_on_connection')}</div>
      ) : bc.accounts.map(acct => (
        <AccountRow
          key={acct.id}
          acct={acct}
          t={t}
          editing={editingId === acct.id}
          editValue={editValue}
          editRef={editRef}
          setEditValue={setEditValue}
          startRename={startRename}
          saveRename={saveRename}
          cancelRename={cancelRename}
        />
      ))}
    </div>
  )
}

interface AccountRowProps {
  acct: BankConnectionAccount
  t: (key: string, opts?: Record<string, unknown>) => string
  editing: boolean
  editValue: string
  editRef: React.RefObject<HTMLInputElement | null>
  setEditValue: (v: string) => void
  startRename: (id: number, name: string) => void
  saveRename: () => void
  cancelRename: () => void
}

function AccountRow({ acct, t, editing, editValue, editRef, setEditValue, startRename, saveRename, cancelRename }: AccountRowProps) {
  const negative = acct.balance_amount != null && parseFloat(acct.balance_amount) < 0
  return (
    <div className="grid grid-cols-[1fr_auto] gap-[14px] items-center px-[18px] py-[13px] border-t border-line">
      <div className="min-w-0">
        {editing ? (
          <input
            ref={editRef}
            className="field h-8 max-w-[260px]"
            value={editValue}
            onChange={e => setEditValue(e.target.value)}
            onBlur={saveRename}
            onKeyDown={e => { if (e.key === 'Enter') saveRename(); if (e.key === 'Escape') cancelRename() }}
            placeholder={t('accounts.rename_placeholder')}
          />
        ) : (
          <button onClick={() => startRename(acct.id, acct.name || '')}
            className="focus-inset inline-flex items-center gap-[7px] font-semibold text-sm rounded-[4px] px-1 py-px -mx-1 -my-px text-left"
            title={t('accounts.rename')}>
            {acct.name || 'Account'}<Icon name="edit" size={13} className="text-ink-faint" />
          </button>
        )}
        <div className="text-ink-faint mono text-[11.5px] mt-0.5">{maskIban(acct.iban)}</div>
      </div>
      <div className="text-right">
        <Amount value={acct.balance_amount} currency={acct.currency} signed={false} className="text-base" forceNegative={negative} />
      </div>
    </div>
  )
}
