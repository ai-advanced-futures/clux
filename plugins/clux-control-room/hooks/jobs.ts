// Pure helpers: turn a background job's state.json into one row of the
// control room. No `$` here, so the tests can call these directly.

import type { BgSession, BgStatus } from '../types'

// Finished sessions older than this drop off the list.
const KEEP_FINISHED_MS = 3 * 24 * 60 * 60 * 1000

type JobState = {
  state?: string
  tempo?: string
  name?: string
  detail?: string
  output?: { result?: string } | null
  cwd?: string
  worktreePath?: string
  sessionId?: string
  updatedAt?: string
  createdAt?: string
}

const ORDER: Record<BgStatus, number> = {
  'needs-input': 0,
  working: 1,
  result: 2,
  failed: 3,
  stopped: 4,
}

export const LABEL: Record<BgStatus, string> = {
  'needs-input': 'needs input',
  working: 'working',
  result: 'result',
  failed: 'failed',
  stopped: 'stopped',
}

function statusOf(job: JobState): BgStatus | undefined {
  if (job.state === 'blocked' || job.tempo === 'blocked') return 'needs-input'
  if (job.state === 'working' || job.state === 'running') return 'working'
  if (job.state === 'done') return 'result'
  if (job.state === 'failed') return 'failed'
  if (job.state === 'stopped') return 'stopped'
  return undefined
}

// True when `path` is `root` or a folder below it.
export function isUnder(path: string | undefined, root: string): boolean {
  if (!path) return false
  const base = root.replace(/\/+$/, '')
  return path === base || path.startsWith(base + '/')
}

// One state.json as a row, or undefined when it is not under one of the
// repository's worktrees, is this session itself, or does not parse.
export function toSession(
  id: string,
  text: string,
  roots: readonly string[],
  selfId: string,
): BgSession | undefined {
  let job: JobState
  try {
    job = JSON.parse(text) as JobState
  } catch {
    return undefined
  }
  if (job.sessionId && job.sessionId === selfId) return undefined
  const isOurs = roots.some(
    root => isUnder(job.cwd, root) || isUnder(job.worktreePath, root),
  )
  if (!isOurs) return undefined
  const status = statusOf(job)
  if (!status) return undefined
  const result = job.output?.result
  const line =
    status === 'result' ? (result ?? job.detail ?? '')
    : status === 'stopped' ? ''
    : (job.detail ?? '')
  const updatedAt = Date.parse(job.updatedAt ?? '') || 0
  // A working session updates on each step, so its age counts from its start.
  const since = status === 'working' ? Date.parse(job.createdAt ?? '') || updatedAt : updatedAt

  return {
    id,
    name: job.name || id,
    status,
    line: line.replace(/\s+/g, ' ').trim(),
    updatedAt,
    since,
  }
}

export function isFresh(session: BgSession, now: number): boolean {
  const isLive = session.status === 'needs-input' || session.status === 'working'
  return isLive || now - session.updatedAt < KEEP_FINISHED_MS
}

export function sortSessions(list: readonly BgSession[]): BgSession[] {
  return [...list].sort(
    (a, b) => ORDER[a.status] - ORDER[b.status] || b.updatedAt - a.updatedAt,
  )
}

export function age(ms: number): string {
  const minutes = Math.max(0, Math.floor(ms / 60000))
  if (minutes < 1) return 'now'
  if (minutes < 60) return `${minutes} min`
  const hours = Math.floor(minutes / 60)
  if (hours < 48) return `${hours} h`
  return `${Math.floor(hours / 24)} d`
}

// The sessions that need input now and did not need input at the last check.
export function newlyBlocked(
  list: readonly BgSession[],
  before: readonly BgSession[],
): BgSession[] {
  const asked = new Set(
    before.filter(s => s.status === 'needs-input').map(s => s.id),
  )
  return list.filter(s => s.status === 'needs-input' && !asked.has(s.id))
}

// The worktree paths that `git worktree list --porcelain` prints.
export function worktreePaths(porcelain: string): string[] {
  return porcelain
    .split('\n')
    .filter(line => line.startsWith('worktree '))
    .map(line => line.slice('worktree '.length))
}
