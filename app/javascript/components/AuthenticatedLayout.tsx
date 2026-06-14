import { useState, useEffect, useCallback } from 'react'
import { useTranslation } from 'react-i18next'
import Sidebar from './Sidebar'
import TopBar from './TopBar'
import Icon from './Icon'
import { api } from '../lib/api'
import type { View } from './SidebarNav'
import DashboardPage from '../pages/DashboardPage'
import TransactionsPage from '../pages/TransactionsPage'
import AccountsPage from '../pages/AccountsPage'
import CategoriesPage from '../pages/CategoriesPage'
import RecurringPage from '../pages/RecurringPage'
import StatisticsPage from '../pages/StatisticsPage'
import SettingsPage from '../pages/SettingsPage'

interface AuthenticatedLayoutProps {
  user: { id: number; email_address: string }
  onLogout: () => void
}

type PageComponent = (props: { onNavigate?: (view: View) => void }) => React.JSX.Element

const pages: Record<View, PageComponent> = {
  dashboard: DashboardPage,
  transactions: TransactionsPage,
  accounts: AccountsPage,
  categories: CategoriesPage,
  recurring: RecurringPage,
  statistics: StatisticsPage,
  settings: SettingsPage,
}

// Views whose data actually responds to the Familie/Privat scope — the switch is shown only
// here. Hidden on categories/settings (read nothing) AND accounts: the accounts page only
// re-detects whether a shared account EXISTS (refreshHasShared); it never reads the scope
// value, and a management page must always list every account regardless of lens.
const SCOPE_VIEWS = new Set<View>(['dashboard', 'transactions', 'recurring', 'statistics'])

function readTheme(): 'light' | 'dark' {
  if (typeof document !== 'undefined' && document.documentElement.classList.contains('dark')) return 'dark'
  return localStorage.getItem('theme') === 'dark' ? 'dark' : 'light'
}

export default function AuthenticatedLayout({ user, onLogout }: AuthenticatedLayoutProps) {
  const { t } = useTranslation()
  const [currentView, setCurrentView] = useState<View>('dashboard')
  const [sidebarOpen, setSidebarOpen] = useState(false)
  const [sidebarCollapsed, setSidebarCollapsed] = useState(() => {
    if (typeof window !== 'undefined') {
      return localStorage.getItem('sidebar-collapsed') === 'true'
    }
    return false
  })
  const [theme, setTheme] = useState<'light' | 'dark'>(readTheme)
  const [uncategorizedCount, setUncategorizedCount] = useState(0)
  const [notification, setNotification] = useState<{ type: 'success' | 'error'; message: string } | null>(null)

  // Persist collapsed preference
  useEffect(() => {
    localStorage.setItem('sidebar-collapsed', String(sidebarCollapsed))
  }, [sidebarCollapsed])

  // Theme: toggle .dark on <html> and persist to localStorage['theme']
  useEffect(() => {
    document.documentElement.classList.toggle('dark', theme === 'dark')
    localStorage.setItem('theme', theme)
  }, [theme])

  // Uncategorized count for the nav badge
  const refreshUncategorizedCount = useCallback(() => {
    api('/api/v1/transactions?uncategorized=true&per=1')
      .then(r => r.ok ? r.json() : null)
      .then(data => { if (data?.meta) setUncategorizedCount(data.meta.total) })
      .catch(() => {})
  }, [])
  useEffect(() => { refreshUncategorizedCount() }, [refreshUncategorizedCount, currentView])

  // Detect bank connection callback URL params
  useEffect(() => {
    const params = new URLSearchParams(window.location.search)
    const successId = params.get('bank_connection_success')
    const errorId = params.get('bank_connection_error')

    if (successId) {
      setNotification({ type: 'success', message: t('settings.bank_connected') })
      setCurrentView('accounts')
      window.history.replaceState({}, '', '/')
    } else if (errorId) {
      setNotification({ type: 'error', message: t('settings.bank_connection_error') })
      setCurrentView('settings')
      window.history.replaceState({}, '', '/')
    }
  }, [t])

  // Auto-dismiss notification
  useEffect(() => {
    if (notification) {
      const timer = setTimeout(() => setNotification(null), 5000)
      return () => clearTimeout(timer)
    }
  }, [notification])

  // Close sidebar on navigate (mobile)
  const handleNavigate = (view: View) => {
    setCurrentView(view)
    setSidebarOpen(false)
  }

  // Close sidebar on escape key
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && sidebarOpen) {
        setSidebarOpen(false)
      }
    }
    document.addEventListener('keydown', handleKeyDown)
    return () => document.removeEventListener('keydown', handleKeyDown)
  }, [sidebarOpen])

  // Prevent body scroll when mobile sidebar is open
  useEffect(() => {
    if (sidebarOpen) {
      document.body.style.overflow = 'hidden'
    } else {
      document.body.style.overflow = ''
    }
    return () => { document.body.style.overflow = '' }
  }, [sidebarOpen])

  const ActivePage = pages[currentView]

  return (
    <div className={`app${sidebarCollapsed ? ' collapsed' : ''}`}>
      {sidebarOpen && <div className="drawer-scrim mobile-only" onClick={() => setSidebarOpen(false)} />}

      <Sidebar
        currentView={currentView}
        onNavigate={handleNavigate}
        collapsed={sidebarCollapsed}
        onToggleCollapsed={() => setSidebarCollapsed(prev => !prev)}
        uncategorizedCount={uncategorizedCount}
        drawerOpen={sidebarOpen}
      />

      <div className="main-col">
        <TopBar
          email={user.email_address}
          onLogout={onLogout}
          onMenuToggle={() => setSidebarOpen(!sidebarOpen)}
          pageTitle={t(`nav.${currentView}`)}
          theme={theme}
          onToggleTheme={() => setTheme(prev => prev === 'dark' ? 'light' : 'dark')}
          showScope={SCOPE_VIEWS.has(currentView)}
        />

        {notification && (
          <div className="toast-wrap" role="status" aria-live="polite">
            <div className={`toast ${notification.type === 'success' ? 'ok' : 'err'}`}>
              <Icon name={notification.type === 'success' ? 'check' : 'alert'} size={18}
                className={'shrink-0 mt-px ' + (notification.type === 'success' ? 'text-income' : 'text-danger')} />
              <div className="flex-1 min-w-0">
                <div className="toast-title">{notification.message}</div>
              </div>
              <button className="ibtn btn-sm w-[26px] h-[26px]" onClick={() => setNotification(null)} aria-label={t('common.close')}>
                <Icon name="close" size={14} />
              </button>
            </div>
          </div>
        )}

        <div className="scroll-area" key={currentView}>
          <ActivePage onNavigate={handleNavigate} />
        </div>
      </div>
    </div>
  )
}
