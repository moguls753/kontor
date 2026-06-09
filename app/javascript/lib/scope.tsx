import { createContext, useContext, useState, useCallback, useEffect, type ReactNode } from 'react'
import { api } from './api'

export type Scope = 'familie' | 'privat'

interface ScopeContextValue {
  scope: Scope
  setScope: (s: Scope) => void
  // true once the user has ≥1 shared account — the switch is only meaningful then
  hasShared: boolean
  // re-detect hasShared on demand (e.g. after toggling an account's shared flag)
  // so the Familie/Privat switch appears without a page reload
  refreshHasShared: () => void
}

const ScopeContext = createContext<ScopeContextValue | null>(null)

function readScope(): Scope {
  if (typeof localStorage === 'undefined') return 'familie'
  return localStorage.getItem('scope') === 'privat' ? 'privat' : 'familie'
}

export function ScopeProvider({ children }: { children: ReactNode }) {
  const [scope, setScopeState] = useState<Scope>(readScope)
  const [hasShared, setHasShared] = useState(false)

  const setScope = useCallback((s: Scope) => {
    setScopeState(s)
    localStorage.setItem('scope', s)
  }, [])

  // Detect whether the user owns at least one shared account. The switch hides
  // itself (and we pin to "familie") when nobody has a Gemeinschaftskonto.
  const refreshHasShared = useCallback(() => {
    api('/api/v1/bank_connections')
      .then(r => (r.ok ? r.json() : []))
      .then((connections: { accounts?: { shared?: boolean }[] }[]) => {
        const shared = Array.isArray(connections) &&
          connections.some(c => (c.accounts || []).some(a => a.shared))
        setHasShared(shared)
        // No shared account ⇒ "privat" is identical to "familie"; normalise to familie.
        if (!shared && readScope() === 'privat') setScope('familie')
      })
      .catch(() => {})
  }, [setScope])

  useEffect(() => { refreshHasShared() }, [refreshHasShared])

  return (
    <ScopeContext.Provider value={{ scope, setScope, hasShared, refreshHasShared }}>
      {children}
    </ScopeContext.Provider>
  )
}

export function useScope(): ScopeContextValue {
  const ctx = useContext(ScopeContext)
  if (!ctx) throw new Error('useScope must be used within a ScopeProvider')
  return ctx
}

// Append the active scope to a query string. "familie" is the backend default, so
// we only send the param when it actually narrows (privat) — keeps URLs clean.
export function withScope(params: URLSearchParams, scope: Scope): URLSearchParams {
  if (scope === 'privat') params.set('scope', 'privat')
  return params
}
