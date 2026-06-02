import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import ThemeToggle from './ThemeToggle'
import { Btn } from './ui'
import Icon from './Icon'
import { api } from '../lib/api'

interface SignupPageProps {
  onSignupSuccess: (user: { id: number; email_address: string }) => void
  onSwitchToLogin: () => void
}

export default function SignupPage({ onSignupSuccess, onSwitchToLogin }: SignupPageProps) {
  const { t } = useTranslation()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [passwordConfirmation, setPasswordConfirmation] = useState('')
  const [errors, setErrors] = useState<string[]>([])
  const [isLoading, setIsLoading] = useState(false)

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setErrors([])
    setIsLoading(true)

    try {
      const response = await api('/user', {
        method: 'POST',
        body: { email_address: email, password, password_confirmation: passwordConfirmation },
      })

      if (response.ok) {
        const user = await response.json()
        onSignupSuccess(user)
      } else {
        const data = await response.json()
        setErrors(data.errors || [t('auth.signup.error_generic')])
      }
    } catch {
      setErrors([t('auth.signup.error_generic')])
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
              {errors.length > 0 && (
                <div role="alert" className="flex flex-col gap-1 text-[12.5px] text-danger font-medium bg-danger-soft px-3 py-2.5 rounded-md">
                  {errors.map((err, i) => <span key={i} className="flex items-center gap-2"><Icon name="alert" size={15} />{err}</span>)}
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
                  placeholder={t('auth.signup.password_placeholder')} required autoComplete="new-password" disabled={isLoading} />
              </label>

              <label className="block">
                <span className="field-label">{t('auth.signup.password_confirm_label')}</span>
                <input className="field" type="password" value={passwordConfirmation} onChange={(e) => setPasswordConfirmation(e.target.value)}
                  placeholder={t('auth.signup.password_confirm_placeholder')} required autoComplete="new-password" disabled={isLoading} />
              </label>

              <Btn variant="primary" type="submit" disabled={isLoading} className="w-full mt-1">
                {isLoading ? t('auth.signup.submitting') : t('auth.signup.submit')}
              </Btn>
            </form>
          </div>

          <p className="text-ink-muted text-center text-[13px] mt-[22px]">
            {t('auth.signup.has_account')}{' '}
            <button onClick={onSwitchToLogin} className="focus-inset text-brass-ink font-[550]">
              {t('auth.signup.sign_in_link')}
            </button>
          </p>
        </div>
      </main>
    </div>
  )
}
