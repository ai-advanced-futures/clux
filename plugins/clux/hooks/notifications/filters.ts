// Pure helpers: the output of `notify-filter.sh list` as rows, and the text
// of the rule box as a rule. No `$` here, so the tests can call these
// directly.
//
// There is deliberately NO regex check here. scripts/notify-filter.sh owns
// the parse of the file and the regex type (grep -E); a second copy in
// TypeScript is the copy that disagrees with the hook (for example on \d).

import type { FilterRow } from '../../types'

// One row for each "<n>\t<kind>\t<text>" line, in file order. The text is the
// rest of the line, tabs and all. A line of another shape is skipped.
export function parseList(stdout: string): FilterRow[] {
  return stdout.split('\n').flatMap(line => {
    const [num, kind, ...rest] = line.split('\t')
    if (rest.length === 0) return []
    const n = Number(num)
    if (!Number.isInteger(n) || n < 1) return []
    if (kind !== 'allow' && kind !== 'deny' && kind !== 'invalid') return []
    return [{ n, kind, text: rest.join('\t') }]
  })
}

// The rules that count: an invalid line hides nothing.
export function validCount(rows: FilterRow[]): number {
  return rows.filter(row => row.kind !== 'invalid').length
}

// What a row reads: "allow  ^feat-", the regexes in one column. An invalid
// row reads as the raw line.
export function rowText(row: FilterRow): string {
  return row.kind === 'invalid' ? row.text : `${row.kind.padEnd(5)}  ${row.text}`
}

// The text the rule box opens with for `e`: "<kind> <regex>", or the raw line
// of an invalid row, so the person can mend it.
export function editValue(row: FilterRow): string {
  return row.kind === 'invalid' ? row.text : `${row.kind} ${row.text}`
}

// The rule box text as a rule: the first word, then the rest, with the spaces
// at the start and the end removed. Null when the first word is not allow or
// deny. An empty regex is still a rule here: the script refuses it, and says
// why.
export function splitRule(text: string): { kind: 'allow' | 'deny'; regex: string } | null {
  const trimmed = text.trim()
  const space = trimmed.search(/\s/)
  const word = space === -1 ? trimmed : trimmed.slice(0, space)
  const regex = space === -1 ? '' : trimmed.slice(space).trim()
  if (word !== 'allow' && word !== 'deny') return null
  return { kind: word, regex }
}
