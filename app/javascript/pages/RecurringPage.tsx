import { useTranslation } from 'react-i18next'
import { Empty } from '../components/ui'

export default function RecurringPage() {
  const { t } = useTranslation()

  return (
    <div className="page">
      <div className="page-head">
        <h1 className="page-title">{t('recurring.title')}</h1>
      </div>
      <div className="panel">
        <Empty icon="recurring" title={t('recurring.empty_title')} body={t('recurring.empty_description')} />
      </div>
    </div>
  )
}
