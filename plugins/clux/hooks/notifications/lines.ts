// Pure helpers: the notification queue file as rows. No `$` here, so the
// tests can call these directly.
//
// There is deliberately NO target parse here. scripts/notification-line.sh
// owns that, and a second copy in TypeScript is the copy that goes out of
// step. These functions only cut the id marker off the text a person reads.

import type { NotifRow } from '../../types'

// What the person reads: the part before the id marker. show-notification.sh
// cuts the same two markers for the status bar.
export function displayText(line: string): string {
  const triple = line.indexOf('|||')
  if (triple !== -1) return line.slice(0, triple)
  const legacy = line.indexOf('|ID:')
  if (legacy !== -1) return line.slice(0, legacy)
  return line
}

// One row for each line that is not empty, in file order. The row keeps the
// whole line, because `jump` and `remove` take the line exactly as it is.
export function toRows(text: string): NotifRow[] {
  return text.split('\n').flatMap(line =>
    line === ''
      ? []
      : [{
          line,
          text: displayText(line),
          kind: line.includes('|||agent:') ? ('agent' as const) : ('window' as const),
        }],
  )
}
