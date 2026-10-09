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

declare module 'claude-code' {
  interface PluginState {
    'clux': {
      sessions: BgSession[]
      notifications: NotifRow[]
    }
  }
}
