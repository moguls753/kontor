import { useTranslation } from 'react-i18next'

const languages = [
  { code: 'en', label: 'English' },
  { code: 'de', label: 'Deutsch' },
]

export default function LanguageSwitcher() {
  const { i18n } = useTranslation()

  return (
    <div className="segmented w-fit">
      {languages.map(({ code, label }) => (
        <button
          key={code}
          className={'px-4 font-sans ' + (i18n.language === code ? 'on' : '')}
          onClick={() => i18n.changeLanguage(code)}
        >
          {label}
        </button>
      ))}
    </div>
  )
}
