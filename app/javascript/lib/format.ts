function getLocale(): string {
  return localStorage.getItem('language') === 'de' ? 'de-DE' : 'en-GB'
}

export function formatAmount(amount: string | number, currency = 'EUR'): string {
  const num = typeof amount === 'string' ? parseFloat(amount) : amount
  if (isNaN(num)) return '—'
  return new Intl.NumberFormat(getLocale(), {
    style: 'currency',
    currency,
    minimumFractionDigits: 2,
  }).format(num)
}

export function formatDate(dateStr: string): string {
  const date = new Date(dateStr + 'T00:00:00')
  return new Intl.DateTimeFormat(getLocale(), {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
  }).format(date)
}

export function formatDateLong(dateStr: string): string {
  const date = new Date(dateStr + 'T00:00:00')
  return new Intl.DateTimeFormat(getLocale(), {
    weekday: 'long',
    day: '2-digit',
    month: 'long',
    year: 'numeric',
  }).format(date)
}

export function formatRelativeTime(dateStr: string): string {
  const date = new Date(dateStr)
  const now = new Date()
  const diffMs = now.getTime() - date.getTime()
  const diffMins = Math.floor(diffMs / 60000)
  const diffHours = Math.floor(diffMs / 3600000)
  const diffDays = Math.floor(diffMs / 86400000)

  const rtf = new Intl.RelativeTimeFormat(getLocale(), { numeric: 'auto' })

  if (diffMins < 1) return rtf.format(0, 'minute')
  if (diffMins < 60) return rtf.format(-diffMins, 'minute')
  if (diffHours < 24) return rtf.format(-diffHours, 'hour')
  if (diffDays < 7) return rtf.format(-diffDays, 'day')
  return formatDate(dateStr.split('T')[0])
}

export function transactionDisplayName(tx: {
  creditor_name: string | null
  debtor_name: string | null
  remittance: string | null
  amount?: string | number
}): string {
  const amt = tx.amount ? (typeof tx.amount === 'string' ? parseFloat(tx.amount) : tx.amount) : 0
  const name = amt >= 0 ? (tx.debtor_name || tx.creditor_name) : (tx.creditor_name || tx.debtor_name)
  return name || tx.remittance?.slice(0, 40) || '—'
}

export function maskIban(iban: string | null): string {
  if (!iban) return '—'
  if (iban.length <= 4) return iban
  return '•••• ' + iban.slice(-4)
}
