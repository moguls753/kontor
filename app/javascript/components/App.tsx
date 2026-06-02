import { useState, useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import LoginPage from './LoginPage'
import SignupPage from './SignupPage'
import AuthenticatedLayout from './AuthenticatedLayout'
import { api } from '../lib/api'

type User = { id: number; email_address: string } | null

export default function App() {
  const { t } = useTranslation()
  const [user, setUser] = useState<User>(null)
  const [isLoading, setIsLoading] = useState(true)
  const [authView, setAuthView] = useState<'login' | 'signup'>('login')

  // Check if user is already logged in on mount
  useEffect(() => {
    const checkAuth = async () => {
      try {
        const response = await api('/me')
        if (response.ok) {
          const userData = await response.json()
          setUser(userData)
        }
      } catch {
        // Not logged in, that's fine
      } finally {
        setIsLoading(false)
      }
    }

    checkAuth()
  }, [])

  // Show loading while checking auth (prevents flash of login page)
  if (isLoading) {
    return (
      <div className="min-h-screen flex items-center justify-center">
        <div className="text-ink-muted text-[13.5px]">
          {t('common.loading')}
        </div>
      </div>
    )
  }

  // Show login/signup or dashboard based on auth state
  if (!user) {
    return authView === 'login'
      ? <LoginPage onLoginSuccess={setUser} onSwitchToSignup={() => setAuthView('signup')} />
      : <SignupPage onSignupSuccess={setUser} onSwitchToLogin={() => setAuthView('login')} />
  }

  return <AuthenticatedLayout user={user} onLogout={() => setUser(null)} />
}
