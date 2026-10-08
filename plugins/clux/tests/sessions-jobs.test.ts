import { describe, expect, test } from 'claude-code/testing'

import { isUnder, sortSessions, toSession, worktreePaths } from '../hooks/sessions/jobs'
import type { BgSession } from '../types'

const ROOT = '/code/clux'
const NOW = Date.parse('2026-10-06T10:05:00.000Z')
const job = (fields: Record<string, unknown>) =>
  JSON.stringify({
    name: 'job',
    cwd: ROOT,
    updatedAt: '2026-10-06T10:00:00.000Z',
    sessionId: 'other',
    ...fields,
  })
const row = (id: string, status: BgSession['status'], updatedAt = 0): BgSession =>
  ({ id, name: id, status, prs: [], line: '', updatedAt })

describe('toSession', () => {
  test('a blocked job needs input and shows its question', () => {
    const s = toSession('a1', job({ state: 'blocked', detail: 'choose: A or B?' }), [ROOT], 'self', NOW)
    expect(s?.status).toBe('needs-input')
    expect(s?.line).toBe('choose: A or B?')
  })

  test('a blocked job shows its needs before its detail', () => {
    const s = toSession('a10', job({ state: 'blocked', needs: 'choose: A or B?', detail: 'blocked' }), [ROOT], 'self', NOW)
    expect(s?.line).toBe('choose: A or B?')
  })

  test('a working job with a blocked tempo needs input', () => {
    const s = toSession('a2', job({ state: 'working', tempo: 'blocked' }), [ROOT], 'self', NOW)
    expect(s?.status).toBe('needs-input')
  })

  test('a done job is done, described by its detail or else its result', () => {
    const withDetail = job({ state: 'done', detail: 'PR merged', output: { result: '8/8 tests' } })
    expect(toSession('a3', withDetail, [ROOT], 'self', NOW)).toEqual(
      expect.objectContaining({ status: 'done', line: 'PR merged' }),
    )
    const withResult = job({ state: 'done', output: { result: '8/8 tests' } })
    expect(toSession('a3', withResult, [ROOT], 'self', NOW)?.line).toBe('8/8 tests')
  })

  test('the PRs come from the pr children', () => {
    const text = job({
      state: 'working',
      children: [
        { id: '28', href: 'https://github.com/o/r/pull/28', kind: 'pr' },
        { id: 'x', href: 'https://example.com', kind: 'issue' },
      ],
    })
    expect(toSession('p1', text, [ROOT], 'self', NOW)?.prs).toEqual([
      { id: '28', href: 'https://github.com/o/r/pull/28' },
    ])
  })

  test('a job in a worktree of the repository counts', () => {
    const text = job({
      state: 'working',
      cwd: '/elsewhere',
      worktreePath: `${ROOT}/.claude/worktrees/feature`,
    })
    expect(toSession('a4', text, [ROOT], 'self', NOW)?.status).toBe('working')
  })

  test('a job in a worktree outside the main tree counts when it is a root', () => {
    const text = job({ state: 'working', cwd: '/code/clux-wt' })
    expect(toSession('a9', text, [ROOT], 'self', NOW)).toBeUndefined()
    expect(toSession('a9', text, [ROOT, '/code/clux-wt'], 'self', NOW)?.status).toBe('working')
  })

  test('a job in a subfolder counts, a job in a sibling repository does not', () => {
    expect(toSession('a5', job({ state: 'done', cwd: `${ROOT}/plugins` }), [ROOT], 'self', NOW)).toBeDefined()
    expect(toSession('a6', job({ state: 'done', cwd: `${ROOT}-other` }), [ROOT], 'self', NOW)).toBeUndefined()
  })

  test('a working job with no update for 30 minutes is unknown, as is an unknown state', () => {
    const quiet = job({ state: 'working', updatedAt: '2026-10-06T09:30:00.000Z' })
    expect(toSession('s1', quiet, [ROOT], 'self', NOW)?.status).toBe('unknown')
    expect(toSession('s2', job({ state: 'paused' }), [ROOT], 'self', NOW)?.status).toBe('unknown')
    const asking = job({ state: 'blocked', updatedAt: '2026-10-05T10:00:00.000Z' })
    expect(toSession('s3', asking, [ROOT], 'self', NOW)?.status).toBe('needs-input')
  })

  test('this session itself and broken files are left out', () => {
    expect(toSession('a7', job({ state: 'working', sessionId: 'self' }), [ROOT], 'self', NOW)).toBeUndefined()
    expect(toSession('a8', '{not json', [ROOT], 'self', NOW)).toBeUndefined()
  })
})

describe('helpers', () => {
  test('isUnder matches the folder and below only', () => {
    expect(isUnder('/a/b', '/a/b')).toBe(true)
    expect(isUnder('/a/b/c', '/a/b/')).toBe(true)
    expect(isUnder('/a/bc', '/a/b')).toBe(false)
  })

  test('sessions that need input come first, then the newest', () => {
    const order = sortSessions([
      row('r', 'done', 9),
      row('w1', 'working', 1),
      row('w2', 'working', 5),
      row('n', 'needs-input', 0),
    ]).map(s => s.id)
    expect(order).toEqual(['n', 'w2', 'w1', 'r'])
  })

  test('worktreePaths reads the porcelain output', () => {
    const out = 'worktree /code/clux\nHEAD abc\nbranch refs/heads/main\n\nworktree /code/clux-wt\nHEAD def\n'
    expect(worktreePaths(out)).toEqual(['/code/clux', '/code/clux-wt'])
  })
})
