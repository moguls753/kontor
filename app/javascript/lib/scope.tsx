import { createContext, useContext, useState, useCallback, useEffect, type ReactNode } from 'react'
import { api } from './api'

export type Scope = 'gemeinsam' | 'privat'

interface ScopeContextValue {
  scope: Scope
  setScope: (s: Scope) => void
  // true once the user has ≥1 shared account — the switch is only meaningful then
  hasShared: boolean
  // re-detect hasShared on demand (e.g. after toggling an account's shared flag)
  // so the Gemeinsam/Privat switch appears without a page reload
  refreshHasShared: () => void
}

const ScopeContext = createContext<ScopeContextValue | null>(null)

function readScope(): Scope {
  // Default (and the migration target for the old 'familie' value) is 'gemeinsam'.
  if (typeof localStorage === 'undefined') return 'gemeinsam'
  return localStorage.getItem('scope') === 'privat' ? 'privat' : 'gemeinsam'
}

export function ScopeProvider({ children }: { children: ReactNode }) {
  const [scope, setScopeState] = useState<Scope>(readScope)
  const [hasShared, setHasShared] = useState(false)

  const setScope = useCallback((s: Scope) => {
    setScopeState(s)
    localStorage.setItem('scope', s)
  }, [])

  // Detect whether the user owns at least one shared account. The switch hides
  // itself (and we pin to "gemeinsam") when nobody has a Gemeinschaftskonto — the
  // backend then collapses that lens to all accounts, so it stays meaningful.
  const refreshHasShared = useCallback(() => {
    api('/api/v1/bank_connections')
      .then(r => (r.ok ? r.json() : []))
      .then((connections: { accounts?: { shared?: boolean }[] }[]) => {
        const shared = Array.isArray(connections) &&
          connections.some(c => (c.accounts || []).some(a => a.shared))
        setHasShared(shared)
        // No shared account ⇒ "privat" has nothing distinct to show; normalise to gemeinsam.
        if (!shared && readScope() === 'privat') setScope('gemeinsam')
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

// Append the active scope to a query string. "gemeinsam" is the backend default (no
// param), so we only send the param for the privat lens — keeps URLs clean and the
// backend only ever branches on `scope == "privat"`.
export function withScope(params: URLSearchParams, scope: Scope): URLSearchParams {
  if (scope === 'privat') params.set('scope', 'privat')
  return params
}
