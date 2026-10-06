import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const ROOT = '/code/clux'
const JOBS = '/home/me/.claude/jobs'
const NOW = Date.parse('2026-10-06T11:00:00.000Z')

const state = (fields: Record<string, unknown>) =>
  JSON.stringify({ cwd: ROOT, updatedAt: '2026-10-06T10:48:00.000Z', ...fields })

// The world beneath the mod: job folders, a repository, a host.
function world(on: On, jobs: Record<string, string>) {
  const ran: string[][] = []
  const toasts: string[] = []
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/me' })
  on('session.repo', () => ({ value: { root: ROOT, remote: null, internal: false, name: null } }))
  on('session.cwd', () => ({ value: `${ROOT}/.claude/worktrees/mine` }))
  on('session.id', () => ({ value: 'self' }))
  on('command.register', () => ({ value: { command: 'control-room' } }))
  on('fs.list', () => ({
    value: Object.keys(jobs).map(name => ({ name, kind: 'dir' as const, size: 0, mtimeMs: 0, isLink: false })),
  }))
  on('fs.read', ($, e) => {
    const id = e.path.slice(JOBS.length + 1).split('/')[0] ?? ''
    const text = jobs[id]
    return text === undefined ? { deny: 'ENOENT' } : { value: text }
  })
  on('process.run', ($, e) => {
    ran.push([...e.argv])
    const stdout = e.argv[0] === 'git' ? `worktree ${ROOT}\nHEAD abc\n\nworktree /code/clux-wt\nHEAD def\n` : ''
    // A Linux machine: no afplay.
    const exitCode = e.argv[0] === 'afplay' ? 127 : 0
    return { value: { exitCode, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('ui.toast', ($, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Box } = $.ui.resolve(e)
    return <Box key="engine-band" />
  })

  return { clock, ran, toasts }
}

const PANE_PROPS = {
  title: 'Background sessions',
  isFocused: false,
  bodyColumns: 80,
  placement: 'dock' as const,
  scroll: { offset: 0, bodyRows: 20 },
  view: {},
}

test('the pane lists the sessions of this repository only', async ($, on) => {
  world(on, {
    ask1: state({ name: 'tenant-registry-p1', state: 'blocked', detail: 'choose: YAML or SQL?' }),
    run1: state({ name: 'ce-db-roster', state: 'working', detail: 'turn 41' }),
    res1: state({ name: 'mods-research', state: 'done', output: { result: '8/8 tests' } }),
    away: state({ name: 'other-repo', state: 'working', cwd: '/code/other' }),
    wt1: state({ name: 'outside-wt', state: 'working', cwd: '/code/clux-wt' }),
    self: state({ name: 'me', state: 'working', sessionId: 'self' }),
  })
  await $.session.start({ cwd: ROOT, surface: 'terminal', isInteractive: true })

  const ui = await $.ui.mount({
    plugin: 'clux-control-room',
    surface: 'terminal',
    component: 'Pane',
    requestId: 'control-room',
    props: PANE_PROPS,
  })
  const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text).join('\n')
  expect(texts).toContain('Background sessions · 4')
  expect(texts).toContain('outside-wt')
  expect(texts).toContain('tenant-registry-p1')
  expect(texts).toContain('choose: YAML or SQL?')
  expect(texts).toContain('8/8 tests')
  expect(texts.includes('other-repo')).toBe(false)
  expect(texts.includes(' me ')).toBe(false)
  expect(await ui.find({ key: 'open-ask1' })).toBeDefined()
  expect(await ui.find({ key: 'read-res1' })).toBeDefined()
  await ui.unmount()
})

test('a new question plays the sound once and raises a toast', async ($, on) => {
  const jobs: Record<string, string> = {
    run1: state({ name: 'fabric-giants', state: 'working', detail: 'building' }),
  }
  const { clock, ran, toasts } = world(on, jobs)
  await $.session.start({ cwd: ROOT, surface: 'terminal', isInteractive: true })
  expect(ran.some(argv => argv[0] === 'paplay')).toBe(false)

  jobs.run1 = state({ name: 'fabric-giants', state: 'blocked', detail: 'choose: A or B?' })
  await clock.advance(5000)
  await clock.settle()
  const plays = () => ran.filter(argv => argv[0] === 'paplay').length
  expect(plays()).toBe(1)
  expect(ran.find(argv => argv[0] === 'paplay')?.[1]).toContain('sounds/needs-input.wav')
  expect(toasts).toEqual(['fabric-giants needs input: choose: A or B?'])

  await clock.advance(5000)
  await clock.settle()
  expect(plays()).toBe(1)
})

test('the band counts the sessions and hides when none is live', async ($, on) => {
  const jobs: Record<string, string> = {
    ask1: state({ name: 'a', state: 'blocked', detail: 'q' }),
    run1: state({ name: 'b', state: 'working' }),
  }
  const { clock } = world(on, jobs)
  await $.session.start({ cwd: ROOT, surface: 'terminal', isInteractive: true })

  const band = {
    plugin: 'clux-control-room',
    surface: 'terminal' as const,
    component: 'AbovePrompt' as const,
    props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 80, scroll: { offset: 0, bodyRows: 10 }, view: {} },
  }
  const ui = await $.ui.mount(band)
  const line = (await ui.findAll({ type: 'Text' })).map(t => t.text).join(' ')
  expect(line).toContain('1 needs input · 1 working')
  await ui.unmount()

  jobs.ask1 = state({ name: 'a', state: 'done', output: { result: 'ok' } })
  jobs.run1 = state({ name: 'b', state: 'stopped' })
  await clock.advance(5000)
  await clock.settle()
  const quiet = await $.ui.mount(band)
  expect(await quiet.find({ key: 'open-room' })).toBeUndefined()
  expect(await quiet.find({ key: 'engine-band' })).toBeDefined()
  await quiet.unmount()
})
