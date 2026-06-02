/* ============================================================================
   KONTOR — icon set.
   One consistent spec: 24×24 grid, 1.6px stroke, round caps & joins, no fill,
   currentColor. Hand-authored — every glyph obeys the same spec so the set
   reads as one family.
   ============================================================================ */
import type { ReactElement } from 'react'

const PATHS: Record<string, ReactElement> = {
  // nav
  dashboard: <path d="M4 13h7V4H4zM13 20h7v-9h-7zM4 20h7v-4H4zM13 8h7V4h-7z" />,
  transactions: <><path d="M5 8h14M5 8l3-3M5 8l3 3" /><path d="M19 16H5m14 0l-3-3m3 3l-3 3" /></>,
  accounts: <><path d="M4 9.5 12 4l8 5.5" /><path d="M5 10v9m4-9v9m6-9v9m4-9v9M3 20h18" /></>,
  categories: <path d="M4 6.5A1.5 1.5 0 0 1 5.5 5H10l2 2.5h6.5A1.5 1.5 0 0 1 20 9v8.5a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 17.5z" />,
  recurring: <><path d="M4 12a8 8 0 0 1 13.5-5.8L20 8M20 4v4h-4" /><path d="M20 12a8 8 0 0 1-13.5 5.8L4 16m0 4v-4h4" /></>,
  statistics: <><path d="M4 20V4m0 16h16" /><path d="M8 16v-4m4 4V8m4 8v-6" /></>,
  settings: <path d="M5 7h14M5 7a2 2 0 1 1 4 0 2 2 0 0 1-4 0M5 17h14M15 17a2 2 0 1 1 4 0 2 2 0 0 1-4 0" />,

  // shell
  menu: <path d="M4 7h16M4 12h16M4 17h16" />,
  sidebarLeft: <><rect x="3.5" y="4.5" width="17" height="15" rx="2" /><path d="M9.5 4.5v15" /></>,
  sun: <><circle cx="12" cy="12" r="4" /><path d="M12 3v2m0 14v2M5 5l1.5 1.5M17.5 17.5 19 19M3 12h2m14 0h2M5 19l1.5-1.5M17.5 6.5 19 5" /></>,
  moon: <path d="M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5" />,
  logout: <><path d="M14 6V5a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2v-1" /><path d="M10 12h10m0 0-3-3m3 3-3 3" /></>,

  // actions
  search: <><circle cx="11" cy="11" r="6.5" /><path d="m16 16 4 4" /></>,
  plus: <path d="M12 5v14M5 12h14" />,
  chevronRight: <path d="m9 6 6 6-6 6" />,
  chevronDown: <path d="m6 9 6 6 6-6" />,
  chevronLeft: <path d="m15 6-6 6 6 6" />,
  arrowRight: <path d="M5 12h14m0 0-6-6m6 6-6 6" />,
  close: <path d="M6 6l12 12M18 6 6 18" />,
  check: <path d="m5 12.5 4.5 4.5L19 7" />,
  sync: <><path d="M20 11a8 8 0 0 0-14-4L4 9m0-5v5h5" /><path d="M4 13a8 8 0 0 0 14 4l2-2m0 5v-5h-5" /></>,
  trash: <path d="M5 7h14M9 7V5h6v2m-7 0 .7 12a1 1 0 0 0 1 1h4.6a1 1 0 0 0 1-1L16 7" />,
  edit: <><path d="M5 19h3l9-9-3-3-9 9z" /><path d="m14 7 3 3" /></>,
  link: <><path d="M10 13a4 4 0 0 0 5.7 0l2.3-2.3a4 4 0 0 0-5.7-5.7L11 6" /><path d="M14 11a4 4 0 0 0-5.7 0L6 13.3a4 4 0 0 0 5.7 5.7L13 18" /></>,
  external: <><path d="M14 5h5v5m0-5-8 8" /><path d="M18 13v4a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4" /></>,

  // money / status
  clock: <><circle cx="12" cy="12" r="8" /><path d="M12 8v4l3 1.8" /></>,
  bank: <><path d="M4 9.5 12 4l8 5.5" /><path d="M5 10v9m14-9v9M3 20h18" /><path d="M9.5 12v4.5m5-4.5v4.5" /></>,
  shield: <><path d="M12 3 5 6v5c0 4.4 3 7.6 7 9 4-1.4 7-4.6 7-9V6z" /><path d="m9.5 12 1.8 1.8L15 10" /></>,
  scan: <><path d="M4 8V6a2 2 0 0 1 2-2h2M16 4h2a2 2 0 0 1 2 2v2M20 16v2a2 2 0 0 1-2 2h-2M8 20H6a2 2 0 0 1-2-2v-2" /><path d="M7 12h10" /></>,
  alert: <><path d="M12 8v5m0 3h.01" /><path d="M10.3 4 3.5 16a2 2 0 0 0 1.7 3h13.6a2 2 0 0 0 1.7-3L13.7 4a2 2 0 0 0-3.4 0z" /></>,
}

export type IconName = keyof typeof PATHS

interface IconProps {
  name: IconName
  size?: number
  stroke?: number
  className?: string
}

export default function Icon({ name, size = 18, stroke = 1.6, className = '' }: IconProps) {
  const path = PATHS[name]
  if (!path) return null
  return (
    <svg
      className={('ico ' + className).trim()}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={stroke}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {path}
    </svg>
  )
}
