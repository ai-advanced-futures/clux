export type BgStatus = 'needs-input' | 'working' | 'unknown' | 'done' | 'failed' | 'stopped'

export type BgPr = { id: string; href: string }

export type BgSession = {
  id: string
  name: string
  status: BgStatus
  prs: BgPr[]
  line: string
  updatedAt: number
}

// One line of the clux notification queue, as the notifications pane draws
// it. `line` is the whole line, the argument of notification-line.sh; `text`
// is what the person reads. The pane does not draw `kind`: the text of an
// agent line already starts with its marker. Enter reads it: the jump of an
// agent line removes the line, so only a window line needs a `remove`.
export type NotifRow = {
  line: string
  text: string
  kind: 'agent' | 'window'
}

// One line of the repo filter file, as `notify-filter.sh list` prints it.
// `n` is the line number in the file, the argument of `set` and `remove`.
// `text` is the regex, or the raw line for an `invalid` row.
export type FilterRow = {
  n: number
  kind: 'allow' | 'deny' | 'invalid'
  text: string
}

// The rule box under the list: closed, adding a rule, or replacing line `n`.
// `value` is the text the box shows; after a refused rule it holds what the
// person typed, so a redraw does not lose it.
export type FilterEditing = null | { mode: 'add'; value: string } | { mode: 'set'; n: number; value: string }

// The Filters view of the notifications pane. `file` is the filter file path,
// or '' when the session cwd is not in a git repo.
export type FiltersState = {
  view: 'notifications' | 'filters'
  file: string
  rules: FilterRow[]
  editing: FilterEditing
}

declare module 'claude-code' {
  interface PluginState {
    'clux': {
      sessions: BgSession[]
      notifications: NotifRow[]
      filters: FiltersState
    }
  }
}
