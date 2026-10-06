export type BgStatus = 'needs-input' | 'working' | 'done' | 'failed' | 'stopped'

export type BgPr = { id: string; href: string }

export type BgSession = {
  id: string
  name: string
  status: BgStatus
  prs: BgPr[]
  line: string
  updatedAt: number
}

declare module 'claude-code' {
  interface PluginState {
    'clux-control-room': {
      sessions: BgSession[]
    }
  }
}
