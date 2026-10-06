export type BgStatus = 'needs-input' | 'working' | 'result' | 'failed' | 'stopped'

export type BgSession = {
  id: string
  name: string
  status: BgStatus
  line: string
  updatedAt: number
  since: number
}

declare module 'claude-code' {
  interface PluginState {
    'clux-control-room': {
      sessions: BgSession[]
      expanded: string
    }
  }
}
