import { useState, useEffect, useRef } from 'react'
import { useTranslation } from 'react-i18next'
import { api } from '../lib/api'
import type { Category } from '../lib/types'
import type { View } from '../components/SidebarNav'
import CategorySuggestionModal from '../components/CategorySuggestionModal'
import { Btn, Empty, catColor, hueFor } from '../components/ui'
import Icon from '../components/Icon'

export default function CategoriesPage({ }: { onNavigate?: (view: View) => void }) {
  const { t, i18n } = useTranslation()
  const [categories, setCategories] = useState<Category[]>([])
  const [isLoading, setIsLoading] = useState(true)
  const [loadError, setLoadError] = useState(false)
  const [isAdding, setIsAdding] = useState(false)
  const [newName, setNewName] = useState('')
  const [editingId, setEditingId] = useState<number | null>(null)
  const [editName, setEditName] = useState('')
  const [error, setError] = useState('')
  const [deletingId, setDeletingId] = useState<number | null>(null)
  const [isCreatingDefaults, setIsCreatingDefaults] = useState(false)
  const [llmConfigured, setLlmConfigured] = useState(false)
  const [showSuggestModal, setShowSuggestModal] = useState(false)
  const addRef = useRef<HTMLInputElement>(null)
  const editRef = useRef<HTMLInputElement>(null)

  const fetchCategories = async () => {
    setIsLoading(true)
    setLoadError(false)
    try {
      const r = await api('/api/v1/categories')
      if (r.ok) setCategories(await r.json())
      else setLoadError(true)
    } catch {
      setLoadError(true)
    } finally {
      setIsLoading(false)
    }
  }

  useEffect(() => {
    fetchCategories()
    api('/api/v1/credentials').then(r => r.ok ? r.json() : null).then(data => {
      if (data?.llm?.configured) setLlmConfigured(true)
    }).catch(() => {})
  }, [])

  useEffect(() => { if (isAdding) addRef.current?.focus() }, [isAdding])
  useEffect(() => { if (editingId) editRef.current?.focus() }, [editingId])

  const handleCreate = async () => {
    if (!newName.trim()) return
    setError('')
    const r = await api('/api/v1/categories', { method: 'POST', body: { category: { name: newName.trim() } } })
    if (r.ok) {
      const created = await r.json()
      setCategories(prev => [...prev, created].sort((a, b) => a.name.localeCompare(b.name)))
      setNewName('')
      setIsAdding(false)
    } else {
      const data = await r.json()
      setError(data.errors?.[0] || t('common.error'))
    }
  }

  const handleUpdate = async (id: number) => {
    if (!editName.trim()) return
    setError('')
    const r = await api(`/api/v1/categories/${id}`, { method: 'PATCH', body: { category: { name: editName.trim() } } })
    if (r.ok) {
      const updated = await r.json()
      setCategories(prev => prev.map(c => c.id === id ? updated : c).sort((a, b) => a.name.localeCompare(b.name)))
      setEditingId(null)
    } else {
      const data = await r.json()
      setError(data.errors?.[0] || t('common.error'))
    }
  }

  const handleCreateDefaults = async () => {
    setIsCreatingDefaults(true)
    setError('')
    try {
      const r = await api('/api/v1/categories/create_defaults', {
        method: 'POST',
        body: { locale: i18n.language },
      })
      if (r.ok) {
        setCategories(await r.json())
      } else {
        setError(t('common.error'))
      }
    } catch {
      setError(t('common.error'))
    } finally {
      setIsCreatingDefaults(false)
    }
  }

  const handleDelete = async (id: number) => {
    const r = await api(`/api/v1/categories/${id}`, { method: 'DELETE' })
    if (r.ok || r.status === 204) {
      setCategories(prev => prev.filter(c => c.id !== id))
    }
    setDeletingId(null)
  }

  const startEdit = (cat: Category) => {
    setEditingId(cat.id)
    setEditName(cat.name)
    setIsAdding(false)
    setDeletingId(null)
  }

  if (isLoading) {
    return (
      <div className="page max-w-[760px]">
        <div className="page-head"><h1 className="page-title">{t('categories.title')}</h1></div>
        <div className="text-ink-muted text-[13.5px]">{t('common.loading')}</div>
      </div>
    )
  }

  if (loadError) {
    return (
      <div className="page max-w-[760px]">
        <div className="page-head"><h1 className="page-title">{t('categories.title')}</h1></div>
        <div className="panel panel-pad flex items-center justify-between gap-3">
          <span className="text-danger text-[13.5px]">{t('common.load_error')}</span>
          <Btn variant="secondary" size="sm" icon="sync" onClick={fetchCategories}>{t('common.retry')}</Btn>
        </div>
      </div>
    )
  }

  return (
    <div className="page max-w-[760px]">
      <div className="page-head">
        <h1 className="page-title">{t('categories.title')}</h1>
        <div className="flex gap-[9px]">
          {llmConfigured && (
            <Btn variant="secondary" icon="scan" onClick={() => setShowSuggestModal(true)}>{t('categories.suggest')}</Btn>
          )}
          {!isAdding && (
            <Btn variant="primary" icon="plus" onClick={() => { setIsAdding(true); setEditingId(null) }}>{t('categories.add')}</Btn>
          )}
        </div>
      </div>

      {error && (
        <div className="panel panel-pad mb-[14px] text-danger text-[13px] border-[color-mix(in_oklab,var(--danger)_40%,var(--line))]">{error}</div>
      )}

      {categories.length === 0 && !isAdding ? (
        <div className="panel">
          <Empty icon="categories" title={t('categories.empty_title')} body={t('categories.empty_description')}>
            <Btn variant="primary" onClick={handleCreateDefaults} disabled={isCreatingDefaults}>
              {isCreatingDefaults ? t('common.loading') : t('categories.create_defaults')}
            </Btn>
          </Empty>
        </div>
      ) : (
        <div className="panel overflow-hidden">
          {isAdding && (
            <div className="flex items-center gap-[9px] px-[18px] py-3 border-b border-line">
              <input
                ref={addRef}
                className="field flex-1"
                placeholder={t('categories.name_placeholder')}
                value={newName}
                onChange={e => setNewName(e.target.value)}
                onKeyDown={e => {
                  if (e.key === 'Enter') handleCreate()
                  if (e.key === 'Escape') { setIsAdding(false); setNewName('') }
                }}
              />
              <Btn variant="primary" size="sm" onClick={handleCreate}>{t('common.save')}</Btn>
              <Btn variant="ghost" size="sm" onClick={() => { setIsAdding(false); setNewName('') }}>{t('common.cancel')}</Btn>
            </div>
          )}

          {categories.map((cat, i) => (
            <div key={cat.id} className={'grid grid-cols-[1fr_auto] gap-4 items-center px-[18px] py-3' + (i || isAdding ? ' border-t border-line' : '')}>
              {editingId === cat.id ? (
                <div className="flex items-center gap-[9px] col-[1/-1]">
                  <input
                    ref={editRef}
                    className="field flex-1"
                    value={editName}
                    onChange={e => setEditName(e.target.value)}
                    onKeyDown={e => {
                      if (e.key === 'Enter') handleUpdate(cat.id)
                      if (e.key === 'Escape') setEditingId(null)
                    }}
                  />
                  <Btn variant="primary" size="sm" onClick={() => handleUpdate(cat.id)}>{t('common.save')}</Btn>
                  <Btn variant="ghost" size="sm" onClick={() => setEditingId(null)}>{t('common.cancel')}</Btn>
                </div>
              ) : (
                <>
                  <div className="flex items-center gap-3 min-w-0">
                    <span className="w-2.5 h-2.5 rounded-[3px] shrink-0" style={{ background: catColor(hueFor(cat.name)) }} />
                    <span className="font-semibold text-sm overflow-hidden text-ellipsis whitespace-nowrap">{cat.name}</span>
                  </div>
                  {deletingId === cat.id ? (
                    <div className="flex items-center gap-2">
                      <span className="text-xs text-danger">{t('categories.confirm_short')}</span>
                      <Btn variant="danger" size="sm" onClick={() => handleDelete(cat.id)}>{t('common.delete')}</Btn>
                      <Btn variant="ghost" size="sm" onClick={() => setDeletingId(null)}>{t('common.cancel')}</Btn>
                    </div>
                  ) : (
                    <div className="flex items-center gap-1">
                      <button className="ibtn btn-sm w-[30px] h-[30px]" title={t('common.edit')} onClick={() => startEdit(cat)}>
                        <Icon name="edit" size={15} />
                      </button>
                      <button className="ibtn btn-sm w-[30px] h-[30px]" title={t('common.delete')} onClick={() => { setDeletingId(cat.id); setEditingId(null) }}>
                        <Icon name="trash" size={15} />
                      </button>
                    </div>
                  )}
                </>
              )}
            </div>
          ))}
        </div>
      )}

      {showSuggestModal && (
        <CategorySuggestionModal onClose={(didCreate) => {
          setShowSuggestModal(false)
          if (didCreate) fetchCategories()
        }} />
      )}
    </div>
  )
}
