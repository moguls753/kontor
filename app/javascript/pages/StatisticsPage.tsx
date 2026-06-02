import { useTranslation } from 'react-i18next'
import { Empty } from '../components/ui'

export default function StatisticsPage() {
  const { t } = useTranslation()

  return (
    <div className="page">
      <div className="page-head">
        <h1 className="page-title">{t('statistics.title')}</h1>
      </div>
      <div className="panel">
        <Empty icon="statistics" title={t('statistics.empty_title')} body={t('statistics.empty_description')} />
      </div>
    </div>
  )
}
