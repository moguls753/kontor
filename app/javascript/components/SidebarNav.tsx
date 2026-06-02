import { Fragment } from 'react'
import { useTranslation } from 'react-i18next'
import Icon from './Icon'
import type { IconName } from './Icon'

export type View = 'dashboard' | 'transactions' | 'accounts' | 'categories' | 'recurring' | 'statistics' | 'settings'

interface SidebarNavProps {
  currentView: View
  onNavigate: (view: View) => void
  collapsed?: boolean
  onToggleCollapsed?: () => void
  uncategorizedCount?: number
}

interface NavItemDef { id: View; icon: IconName; count?: 'uncat' }

const NAV: { group: string; items: NavItemDef[] }[] = [
  {
    group: 'shell.section_overview',
    items: [
      { id: 'dashboard', icon: 'dashboard' },
      { id: 'transactions', icon: 'transactions', count: 'uncat' },
      { id: 'accounts', icon: 'accounts' },
    ],
  },
  {
    group: 'shell.section_manage',
    items: [
      { id: 'categories', icon: 'categories' },
      { id: 'recurring', icon: 'recurring' },
      { id: 'statistics', icon: 'statistics' },
      { id: 'settings', icon: 'settings' },
    ],
  },
]

export default function SidebarNav({ currentView, onNavigate, collapsed = false, onToggleCollapsed, uncategorizedCount = 0 }: SidebarNavProps) {
  const { t } = useTranslation()

  const renderItem = (item: NavItemDef) => {
    const label = t(`nav.${item.id}`)
    const active = currentView === item.id
    const count = item.count === 'uncat' ? uncategorizedCount : undefined
    const body = (
      <button
        key={item.id}
        className={`nav-item${active ? ' active' : ''}`}
        onClick={() => onNavigate(item.id)}
        aria-current={active ? 'page' : undefined}
        title={collapsed ? label : undefined}
        aria-label={collapsed ? label : undefined}
      >
        <Icon name={item.icon} size={18} />
        <span className="nav-label">{label}</span>
        {count != null && count > 0 && <span className="nav-count">{count}</span>}
        {collapsed && <span className="tip-pop">{label}{count ? ' · ' + count : ''}</span>}
      </button>
    )
    return collapsed ? <div key={item.id} className="tip">{body}</div> : body
  }

  return (
    <>
      <nav className="nav" aria-label="Primary">
        {NAV.map((sec, i) => (
          <Fragment key={sec.group}>
            {!collapsed && <div className="nav-group-label eyebrow">{t(sec.group)}</div>}
            {collapsed && i > 0 && <div className="divider my-2 mx-1.5" />}
            {sec.items.map(renderItem)}
          </Fragment>
        ))}
      </nav>

      {onToggleCollapsed && (
        <div className="sidebar-foot desktop-only">
          <button
            className="collapse-btn"
            onClick={onToggleCollapsed}
            title={collapsed ? t('common.expand_sidebar') : t('common.collapse_sidebar')}
            aria-label={collapsed ? t('common.expand_sidebar') : t('common.collapse_sidebar')}
          >
            <Icon name="sidebarLeft" size={17} />
            {!collapsed && <span className="sidebar-foot-text">{t('common.collapse')}</span>}
          </button>
        </div>
      )}
    </>
  )
}
