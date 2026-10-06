import { describe, expect, test } from 'claude-code/testing'

import { age, isUnder, newlyBlocked, sortSessions, toSession, worktreePaths } from '../hooks/jobs'

const ROOT = '/code/clux'
const job = (fields: Record<string, unknown>) =>
  JSON.stringify({
    name: 'job',
    cwd: ROOT,
    updatedAt: '2026-10-06T10:00:00.000Z',
    sessionId: 'other',
    ...fields,
  })

describe('toSession', () => {
  test('a blocked job needs input and shows its question', () => {
    const s = toSession('a1', job({ state: 'blocked', detail: 'choose: A or B?' }), [ROOT], 'self')
    expect(s?.status).toBe('needs-input')
    expect(s?.line).toBe('choose: A or B?')
  })

  test('a working job with a blocked tempo needs input', () => {
    const s = toSession('a2', job({ state: 'working', tempo: 'blocked' }), [ROOT], 'self')
    expect(s?.status).toBe('needs-input')
  })

  test('a done job shows its result line', () => {
    const text = job({ state: 'done', detail: 'old', output: { result: '8/8 tests' } })
    expect(toSession('a3', text, [ROOT], 'self')?.line).toBe('8/8 tests')
  })

  test('a working job counts its age from its start, a blocked job from its last change', () => {
    const created = '2026-10-06T09:00:00.000Z'
    const working = toSession('b1', job({ state: 'working', createdAt: created }), [ROOT], 'self')
    expect(working?.since).toBe(Date.parse(created))
    const blocked = toSession('b2', job({ state: 'blocked', createdAt: created }), [ROOT], 'self')
    expect(blocked?.since).toBe(Date.parse('2026-10-06T10:00:00.000Z'))
  })

  test('a job in a worktree of the repository counts', () => {
    const text = job({
      state: 'working',
      cwd: '/elsewhere',
      worktreePath: `${ROOT}/.claude/worktrees/feature`,
    })
    expect(toSession('a4', text, [ROOT], 'self')?.status).toBe('working')
  })

  test('a job in a worktree outside the main tree counts when it is a root', () => {
    const text = job({ state: 'working', cwd: '/code/clux-wt' })
    expect(toSession('a9', text, [ROOT], 'self')).toBeUndefined()
    expect(toSession('a9', text, [ROOT, '/code/clux-wt'], 'self')?.status).toBe('working')
  })

  test('a job in a subfolder counts, a job in a sibling repository does not', () => {
    expect(toSession('a5', job({ state: 'done', cwd: `${ROOT}/plugins` }), [ROOT], 'self')).toBeDefined()
    expect(toSession('a6', job({ state: 'done', cwd: `${ROOT}-other` }), [ROOT], 'self')).toBeUndefined()
  })

  test('this session itself and broken files are left out', () => {
    expect(toSession('a7', job({ state: 'working', sessionId: 'self' }), [ROOT], 'self')).toBeUndefined()
    expect(toSession('a8', '{not json', [ROOT], 'self')).toBeUndefined()
  })
})

describe('helpers', () => {
  test('isUnder matches the folder and below only', () => {
    expect(isUnder('/a/b', '/a/b')).toBe(true)
    expect(isUnder('/a/b/c', '/a/b/')).toBe(true)
    expect(isUnder('/a/bc', '/a/b')).toBe(false)
  })

  test('sessions that need input come first, then the newest', () => {
    const at = (id: string, status: 'working' | 'needs-input' | 'result', updatedAt: number) =>
      ({ id, name: id, status, line: '', updatedAt, since: updatedAt })
    const order = sortSessions([
      at('r', 'result', 9),
      at('w1', 'working', 1),
      at('w2', 'working', 5),
      at('n', 'needs-input', 0),
    ]).map(s => s.id)
    expect(order).toEqual(['n', 'w2', 'w1', 'r'])
  })

  test('age reads as minutes, hours, days', () => {
    expect(age(30_000)).toBe('now')
    expect(age(12 * 60_000)).toBe('12 min')
    expect(age(2 * 3_600_000)).toBe('2 h')
    expect(age(72 * 3_600_000)).toBe('3 d')
  })

  test('newlyBlocked names only the new questions', () => {
    const s = { name: 'x', line: '', updatedAt: 0, since: 0 }
    const old = { ...s, id: 'old', status: 'needs-input' as const }
    const list = [
      old,
      { ...s, id: 'new', status: 'needs-input' as const },
      { ...s, id: 'busy', status: 'working' as const },
    ]
    const before = [old, { ...s, id: 'new', status: 'working' as const }]
    expect(newlyBlocked(list, before).map(x => x.id)).toEqual(['new'])
  })

  test('worktreePaths reads the porcelain output', () => {
    const out = 'worktree /code/clux\nHEAD abc\nbranch refs/heads/main\n\nworktree /code/clux-wt\nHEAD def\n'
    expect(worktreePaths(out)).toEqual(['/code/clux', '/code/clux-wt'])
  })
})
