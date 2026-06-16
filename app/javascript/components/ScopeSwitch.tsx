import { useTranslation } from 'react-i18next'
import { useScope, type Scope } from '../lib/scope'

const scopes: Scope[] = ['gemeinsam', 'privat']

export default function ScopeSwitch() {
  const { t } = useTranslation()
  const { scope, setScope, hasShared } = useScope()

  // Only meaningful when the user has at least one shared (Gemeinschafts-) account.
  if (!hasShared) return null

  return (
    <div className="segmented w-fit" role="group" aria-label={t('scope.label')}>
      {scopes.map(code => (
        <button
          key={code}
          className={'px-4 font-sans ' + (scope === code ? 'on' : '')}
          aria-pressed={scope === code}
          onClick={() => setScope(code)}
        >
          {t(`scope.${code}`)}
        </button>
      ))}
    </div>
  )
}
