import { useTranslation } from 'react-i18next'
import { api } from '../lib/api'
import Icon from './Icon'
import ScopeSwitch from './ScopeSwitch'

interface TopBarProps {
  email: string
  onLogout: () => void
  onMenuToggle: () => void
  pageTitle: string
  theme: 'light' | 'dark'
  onToggleTheme: () => void
  showScope: boolean
}

export default function TopBar({ email, onLogout, onMenuToggle, pageTitle, theme, onToggleTheme, showScope }: TopBarProps) {
  const { t } = useTranslation()

  const handleLogout = async () => {
    try {
      const response = await api('/session', { method: 'DELETE' })
      if (response.ok || response.status === 204) {
        onLogout()
      }
    } catch {
      onLogout()
    }
  }

  return (
    <header className="topbar">
      <button className="ibtn mobile-only" onClick={onMenuToggle} aria-label={t('shell.menu')}>
        <Icon name="menu" size={20} />
      </button>
      <div className="page-title desktop-only text-base">{pageTitle}</div>
      <div className="flex-1" />

      {/* Scope (Familie/Privat) is a global lens, but only rendered where the page actually
          reads it — hidden on Kategorien/Einstellungen, where it would be a no-op. */}
      {showScope && (
        <>
          <ScopeSwitch />
          <div className="hairline-v desktop-only h-[26px] mx-1" />
        </>
      )}

      {/* theme */}
      <button className="ibtn" onClick={onToggleTheme} aria-label={t('shell.toggle_theme')} title={t('shell.toggle_theme')}>
        <Icon name={theme === 'dark' ? 'sun' : 'moon'} size={19} />
      </button>

      <div className="hairline-v desktop-only h-[26px] mx-1" />

      {/* account */}
      <div className="desktop-only flex items-center gap-2.5">
        <div className="text-right leading-[1.25]">
          <div className="text-[12.5px] font-[550] max-w-[220px] overflow-hidden text-ellipsis whitespace-nowrap">{email}</div>
        </div>
        <span className="icon-tile icon-tile-ink w-[34px] h-[34px] text-[13px]">
          {(email[0] || '?').toUpperCase()}
        </span>
      </div>
      <button className="ibtn" onClick={handleLogout} aria-label={t('common.sign_out')} title={t('common.sign_out')}>
        <Icon name="logout" size={18} />
      </button>
    </header>
  )
}
