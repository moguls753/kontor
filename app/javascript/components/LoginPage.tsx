import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import ThemeToggle from './ThemeToggle'
import { Btn } from './ui'
import Icon from './Icon'
import { api } from '../lib/api'

interface LoginPageProps {
  onLoginSuccess: (user: { id: number; email_address: string }) => void
  onSwitchToSignup: () => void
}

export default function LoginPage({ onLoginSuccess, onSwitchToSignup }: LoginPageProps) {
  const { t } = useTranslation()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [isLoading, setIsLoading] = useState(false)

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setError('')
    setIsLoading(true)

    try {
      const response = await api('/session', {
        method: 'POST',
        body: { email_address: email, password },
      })

      if (response.ok) {
        const user = await response.json()
        onLoginSuccess(user)
      } else {
        const data = await response.json()
        setError(data.error || t('auth.login.error_invalid'))
      }
    } catch {
      setError(t('auth.login.error_generic'))
    } finally {
      setIsLoading(false)
    }
  }

  return (
    <div className="min-h-screen flex flex-col">
      <header className="flex justify-end p-[22px]">
        <ThemeToggle />
      </header>

      <main className="flex-1 flex items-center justify-center px-6 pb-20">
        <div className="w-full max-w-[380px]">
          <div className="mb-8 text-center">
            <div className="icon-tile icon-tile-ink brass-inset w-11 h-11 mx-auto mb-4 rounded-md text-[22px]">
              K
            </div>
            <h1 className="page-title text-[28px]">{t('auth.title')}</h1>
            <p className="text-ink-muted text-[13.5px] mt-1">{t('auth.subtitle')}</p>
          </div>

          <div className="panel panel-pad">
            <form onSubmit={handleSubmit} className="grid gap-4">
              {error && (
                <div role="alert" className="flex items-center gap-2 text-[12.5px] text-danger font-medium bg-danger-soft px-3 py-2.5 rounded-md">
                  <Icon name="alert" size={15} />{error}
                </div>
              )}

              <label className="block">
                <span className="field-label">{t('auth.email_label')}</span>
                <input className="field" type="email" value={email} onChange={(e) => setEmail(e.target.value)}
                  placeholder={t('auth.email_placeholder')} required autoComplete="email" autoFocus disabled={isLoading} />
              </label>

              <label className="block">
                <span className="field-label">{t('auth.password_label')}</span>
                <input className="field" type="password" value={password} onChange={(e) => setPassword(e.target.value)}
                  placeholder={t('auth.login.password_placeholder')} required autoComplete="current-password" disabled={isLoading} />
              </label>

              <Btn variant="primary" type="submit" disabled={isLoading} className="w-full mt-1">
                {isLoading ? t('auth.login.submitting') : t('auth.login.submit')}
              </Btn>
            </form>
          </div>

          <p className="text-ink-muted text-center text-[13px] mt-[22px]">
            {t('auth.login.no_account')}{' '}
            <button onClick={onSwitchToSignup} className="focus-inset text-brass-ink font-[550]">
              {t('auth.login.sign_up_link')}
            </button>
          </p>
        </div>
      </main>
    </div>
  )
}
