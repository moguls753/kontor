import { useTranslation } from 'react-i18next'
import SidebarNav from './SidebarNav'
import type { View } from './SidebarNav'

interface SidebarProps {
  currentView: View
  onNavigate: (view: View) => void
  collapsed?: boolean
  onToggleCollapsed?: () => void
  uncategorizedCount?: number
  drawerOpen?: boolean
}

export default function Sidebar({ currentView, onNavigate, collapsed = false, onToggleCollapsed, uncategorizedCount = 0, drawerOpen = false }: SidebarProps) {
  const { t } = useTranslation()
  return (
    <aside className={`sidebar${drawerOpen ? ' drawer-open' : ''}`}>
      <div className="brand">
        <div className="brand-mark">K</div>
        <div className="brand-text min-w-0">
          <div className="brand-name">{t('app.name')}</div>
          <div className="brand-sub">{t('app.tagline')}</div>
        </div>
      </div>

      <SidebarNav
        currentView={currentView}
        onNavigate={onNavigate}
        collapsed={collapsed}
        onToggleCollapsed={onToggleCollapsed}
        uncategorizedCount={uncategorizedCount}
      />
    </aside>
  )
}
