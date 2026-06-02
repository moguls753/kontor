import { useState, useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import Icon from './Icon'

export default function ThemeToggle() {
  const { t } = useTranslation()
  const [isDark, setIsDark] = useState(() => {
    if (typeof window !== 'undefined') {
      const stored = localStorage.getItem('theme')
      if (stored) return stored === 'dark'
      return window.matchMedia('(prefers-color-scheme: dark)').matches
    }
    return false
  })

  useEffect(() => {
    const root = document.documentElement
    if (isDark) {
      root.classList.add('dark')
      localStorage.setItem('theme', 'dark')
    } else {
      root.classList.remove('dark')
      localStorage.setItem('theme', 'light')
    }
  }, [isDark])

  return (
    <button
      onClick={() => setIsDark(!isDark)}
      className="ibtn"
      aria-label={t('shell.toggle_theme')}
      title={t('shell.toggle_theme')}
    >
      <Icon name={isDark ? 'sun' : 'moon'} size={19} />
    </button>
  )
}
