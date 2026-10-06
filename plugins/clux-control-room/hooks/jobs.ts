// Pure helpers: turn a background job's state.json into one row of the
// control room. No `$` here, so the tests can call these directly.

import type { BgPr, BgSession, BgStatus } from '../types'

// Finished sessions older than this drop off the list.
const KEEP_FINISHED_MS = 3 * 24 * 60 * 60 * 1000

type JobState = {
  state?: string
  tempo?: string
  name?: string
  detail?: string
  output?: { result?: string } | null
  children?: { id?: string; href?: string; kind?: string }[]
  cwd?: string
  worktreePath?: string
  sessionId?: string
  updatedAt?: string
}

const ORDER: Record<BgStatus, number> = {
  'needs-input': 0,
  working: 1,
  done: 2,
  failed: 3,
  stopped: 4,
}

export const LABEL: Record<BgStatus, string> = {
  'needs-input': 'needs input',
  working: 'working',
  done: 'done',
  failed: 'failed',
  stopped: 'stopped',
}

function statusOf(job: JobState): BgStatus | undefined {
  if (job.state === 'blocked' || job.tempo === 'blocked') return 'needs-input'
  if (job.state === 'working' || job.state === 'running') return 'working'
  if (job.state === 'done') return 'done'
  if (job.state === 'failed') return 'failed'
  if (job.state === 'stopped') return 'stopped'
  return undefined
}

function prsOf(job: JobState): BgPr[] {
  return (job.children ?? []).flatMap(child =>
    child.kind === 'pr' && child.id && child.href
      ? [{ id: child.id, href: child.href }]
      : [],
  )
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
  // The description: what the session does now, or the result it gave.
  const line = status === 'stopped' ? '' : (job.detail || job.output?.result || '')

  return {
    id,
    name: job.name || id,
    status,
    prs: prsOf(job),
    line: line.replace(/\s+/g, ' ').trim(),
    updatedAt: Date.parse(job.updatedAt ?? '') || 0,
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
