import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On } from 'claude-code'

const ROOT = '/code/clux'
const JOBS = '/home/me/.claude/jobs'
const NOW = Date.parse('2026-10-06T11:00:00.000Z')

const state = (fields: Record<string, unknown>) =>
  JSON.stringify({ cwd: ROOT, updatedAt: '2026-10-06T10:48:00.000Z', ...fields })

// The world beneath the mod: job folders, a repository, a host.
function world(on: On, jobs: Record<string, string>, env: Record<string, string> = {}) {
  const ran: string[][] = []
  const toasts: string[] = []
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/me', ...env })
  on('session.repo', () => ({ value: { root: ROOT, remote: null, internal: false, name: null } }))
  on('session.cwd', () => ({ value: `${ROOT}/.claude/worktrees/mine` }))
  on('session.id', () => ({ value: 'self' }))
  const lists = { count: 0 }
  on('fs.list', () => {
    lists.count += 1
    return {
      value: Object.keys(jobs).map(name => ({ name, kind: 'dir' as const, size: 0, mtimeMs: 0, isLink: false })),
    }
  })
  on('fs.read', ($, e) => {
    const id = e.path.slice(JOBS.length + 1).split('/')[0] ?? ''
    const text = jobs[id]
    return text === undefined ? { deny: 'ENOENT' } : { value: text }
  })
  on('process.run', ($, e) => {
    ran.push([...e.argv])
    const stdout =
      e.argv[0] === 'git' ? `worktree ${ROOT}\nHEAD abc\n\nworktree /code/clux-wt\nHEAD def\n`
      : e.argv[1] === 'display-message' ? '$3\n'
      : ''
    return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('fs.stat', ($, e) => ({
    value: { kind: 'dir' as const, size: 0, mtimeMs: 0, isLink: false, realPath: e.path },
  }))
  on('ui.log', () => ({ value: undefined }))
  on('ui.toast', ($, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  // The panes this plugin has open, as the engine would keep them.
  const panes = new Set<string>()
  on('ui.open', ($, e) => {
    panes.add(e.id)
    return { value: { isPlaced: true } }
  })
  on('ui.close', ($, e) => {
    panes.delete(e.id)
    return { value: undefined }
  })
  on('ui.panes', () => ({
    value: [...panes].map(id => ({ id, title: id, isShown: true, isFocused: true, isPlaced: true, plugin: 'clux' })),
  }))
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  // The prompt box: the draft, the cursor, and what the mod put in it.
  const box = { text: '', cursor: 0, isRefused: false }
  const fills: { text: string; mode: string }[] = []
  on('prompt.read', () => ({ value: { text: box.text, cursor: box.cursor } }))
  on('prompt.fill', ($, e) => {
    if (box.isRefused) return { isFilled: false }
    fills.push({ text: e.text, mode: e.mode })
    return { isFilled: true }
  })
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Box } = $.ui.resolve(e)
    return <Box key="engine-band" />
  })
  on('ui.render', { component: 'SessionMode' }, ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    return (
      <Box key="engine-modes">
        <Text dimColor>{e.props.modes.join(' & ')}</Text>
      </Box>
    )
  })

  return { clock, ran, toasts, lists, panes, box, fills }
}

const PANE_PROPS = {
  title: 'Background sessions',
  isFocused: false,
  bodyColumns: 80,
  placement: 'dock' as const,
  scroll: { offset: 0, bodyRows: 20 },
  view: {},
}

test('the pane lists name, status, PRs and description for this repository only', async ($, on) => {
  world(on, {
    ask1: state({ name: 'tenant-registry-p1', state: 'blocked', detail: 'choose: YAML or SQL?' }),
    run1: state({ name: 'ce-db-roster', state: 'working', detail: 'turn 41' }),
    res1: state({
      name: 'mods-research',
      state: 'done',
      output: { result: '8/8 tests' },
      children: [{ id: '28', href: 'https://github.com/o/r/pull/28', kind: 'pr' }],
    }),
    away: state({ name: 'other-repo', state: 'working', cwd: '/code/other' }),
    wt1: state({ name: 'outside-wt', state: 'working', cwd: '/code/clux-wt' }),
    self: state({ name: 'me', state: 'working', sessionId: 'self' }),
  })
  await $.session.start({ cwd: ROOT, surface: 'terminal', isInteractive: true })

  const ui = await $.ui.mount({
    plugin: 'clux',
    surface: 'terminal',
    component: 'Pane',
    requestId: 'sessions',
    props: PANE_PROPS,
  })
  const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text).join('\n')
  const names = (await ui.findAll({ type: 'Button' }))
    .filter(b => b.props.plain)
    .map(b => String(b.props.label).trim())
  expect(texts).toContain('Background sessions · 4')
  expect(names).toEqual(['tenant-registry-p1', 'ce-db-roster', 'outside-wt', 'mods-research'])
  expect(texts).toContain('needs input')
  expect(texts).toContain('done')
  expect(texts.includes('result')).toBe(false)
  expect(texts).toContain('choose: YAML or SQL?')
  expect(texts).toContain('8/8 tests')
  const link = await ui.find({ type: 'Link' })
  expect(link?.props.href).toBe('https://github.com/o/r/pull/28')
  const first = await ui.find({ key: 'mention-ask1' })
  expect(first?.props.hotkey).toBe('1')
  expect(first?.props.autoFocus).toBe(true)
  expect((await ui.find({ key: 'mention-run1' }))?.props.autoFocus).toBeUndefined()
  await ui.unmount()
})

const mountPane = ($: Engine) =>
  $.ui.mount({
    plugin: 'clux',
    surface: 'terminal',
    component: 'Pane',
    requestId: 'sessions',
    props: PANE_PROPS,
  })

test('Enter on a row inserts its @name at the cursor and closes the pane', async ($, on) => {
  const { ran, panes, box, fills } = world(
    on,
    { ask1: state({ name: 'tenant-registry-p1', state: 'blocked', detail: 'q' }) },
    { TMUX: '/tmp/tmux-1000/default,1,0', TMUX_PANE: '%5' },
  )
  await $.session.start({ cwd: ROOT, surface: 'terminal', isInteractive: true })
  await runSessions($)
  box.text = 'ask  for its status'
  box.cursor = 4
  const ui = await mountPane($)
  await ui.press({ key: 'mention-ask1' })
  expect(fills).toEqual([{ text: '@tenant-registry-p1 ', mode: 'insert' }])
  expect(panes.has('sessions')).toBe(false)
  // The pane no longer opens a session.
  expect(ran.some(argv => argv[0] === 'tmux' || argv[0] === 'claude')).toBe(false)
  await ui.unmount()
})

test('a pane without the keys says how to move into it', async ($, on) => {
  world(on, { ask1: state({ name: 'fabric-giants', state: 'working' }) })
  await $.session.start({ cwd: ROOT, surface: 'terminal', isInteractive: true })
  const hint = 'ctrl+x tab: move into the list'
  const texts = async (isFocused: boolean) => {
    const ui = await $.ui.mount({
      plugin: 'clux',
      surface: 'terminal',
      component: 'Pane',
      requestId: 'sessions',
      props: { ...PANE_PROPS, isFocused },
    })
    const all = (await ui.findAll({ type: 'Text' })).map(t => t.text).join('\n')
    await ui.unmount()
    return all
  }
  // A draft in the message box: Claude Code opens the pane without the keys.
  expect(await texts(false)).toContain(hint)
  expect((await texts(true)).includes(hint)).toBe(false)
})

test('a cursor right after a word gets a space before the @name', async ($, on) => {
  const { box, fills } = world(on, { ask1: state({ name: 'fabric-giants', state: 'working' }) })
  await $.session.start({ cwd: ROOT, surface: 'terminal', isInteractive: true })
  box.text = 'ping'
  box.cursor = 4
  const ui = await mountPane($)
  await ui.press({ key: 'mention-ask1' })
  expect(fills).toEqual([{ text: ' @fabric-giants ', mode: 'insert' }])
  await ui.unmount()
})

test('a box that refuses the text shows the @name in a toast', async ($, on) => {
  const { box, fills, toasts } = world(on, { ask1: state({ name: 'fabric-giants', state: 'working' }) })
  await $.session.start({ cwd: ROOT, surface: 'terminal', isInteractive: true })
  box.isRefused = true
  const ui = await mountPane($)
  await ui.press({ key: 'mention-ask1' })
  expect(fills).toEqual([])
  expect(toasts).toEqual(['Could not put @fabric-giants in the message box.'])
  await ui.unmount()
})

test('a new question raises no toast and plays no sound', async ($, on) => {
  const jobs: Record<string, string> = {
    run1: state({ name: 'fabric-giants', state: 'working', detail: 'building' }),
  }
  const { clock, ran, toasts } = world(on, jobs)
  await $.session.start({ cwd: ROOT, surface: 'terminal', isInteractive: true })

  jobs.run1 = state({ name: 'fabric-giants', state: 'blocked', detail: 'choose: A or B?' })
  await clock.advance(5000)
  await clock.settle()
  jobs.run1 = state({ name: 'fabric-giants', state: 'blocked', detail: 'choose: C or D?' })
  await clock.advance(5000)
  await clock.settle()

  // The poll saw the question: the footer counts it.
  const ui = await $.ui.mount({
    plugin: 'clux',
    surface: 'terminal',
    component: 'SessionMode',
    props: { modes: [] },
  })
  expect((await ui.find({ key: 'open-sessions' }))?.props.label).toBe('1 needs input')
  await ui.unmount()

  expect(toasts).toEqual([])
  // Only git and tmux run: no audio player.
  expect(ran.filter(argv => argv[0] !== 'git' && argv[0] !== 'tmux')).toEqual([])
})

const runSessions = ($: Engine, args = '') =>
  $.command.run({
    command: 'clux:sessions',
    args,
    origin: { kind: 'composer' },
    presentation: { isFullscreen: false, columns: 100 },
  })

test('/clux:sessions opens the pane, and /clux:sessions again closes it', async ($, on) => {
  const { panes } = world(on, {})
  await $.session.start({ cwd: ROOT, surface: 'terminal', isInteractive: true })

  expect((await runSessions($)).text).toContain('opened')
  expect(panes.has('sessions')).toBe(true)
  expect((await runSessions($)).text).toContain('closed')
  expect(panes.has('sessions')).toBe(false)

  await runSessions($, 'on')
  await runSessions($, 'on')
  expect(panes.has('sessions')).toBe(true)
  await runSessions($, 'off')
  expect(panes.has('sessions')).toBe(false)
})

test('a run with no person at the prompt does not poll', async ($, on) => {
  const { clock, lists } = world(on, {})
  await $.session.start({ cwd: ROOT, surface: null, isInteractive: false })
  await clock.advance(5000)
  await clock.settle()
  expect(lists.count).toBe(0)
})

test('a start that runs twice keeps one timer', async ($, on) => {
  const jobs: Record<string, string> = {
    run1: state({ name: 'fabric-giants', state: 'working', detail: 'building' }),
  }
  const { clock, lists } = world(on, jobs)
  await $.session.start({ cwd: ROOT, surface: 'terminal', isInteractive: true })
  await $.session.start({ cwd: ROOT, surface: 'terminal', isInteractive: true })

  const before = lists.count
  await clock.advance(5000)
  await clock.settle()
  expect(lists.count - before).toBe(1)
})

test('the footer label holds the chord, and the band stays empty', async ($, on) => {
  const jobs: Record<string, string> = {
    ask1: state({ name: 'a', state: 'blocked', detail: 'q' }),
    run1: state({ name: 'b', state: 'working' }),
  }
  const { clock } = world(on, jobs)
  await $.session.start({ cwd: ROOT, surface: 'terminal', isInteractive: true })

  const footer = {
    plugin: 'clux',
    surface: 'terminal' as const,
    component: 'SessionMode' as const,
    props: { modes: ['focus'] },
  }
  const ui = await $.ui.mount(footer)
  const label = await ui.find({ key: 'open-sessions' })
  expect(label?.props.label).toBe('1 needs input')
  expect(label?.props.dimColor).toBe(false)
  expect(label?.props.action).toBe('app:cycleDiffBase')
  expect(await ui.find({ key: 'engine-modes' })).toBeDefined()
  await ui.unmount()

  jobs.ask1 = state({ name: 'a', state: 'done', output: { result: 'ok' } })
  await clock.advance(5000)
  await clock.settle()
  const quiet = await $.ui.mount({ ...footer, props: { modes: [] } })
  const quietLabel = await quiet.find({ key: 'open-sessions' })
  expect(quietLabel?.props.label).toBe('sessions')
  expect(quietLabel?.props.dimColor).toBe(true)
  await quiet.unmount()

  const band = await $.ui.mount({
    plugin: 'clux',
    surface: 'terminal',
    component: 'AbovePrompt',
    props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 80, scroll: { offset: 0, bodyRows: 10 }, view: {} },
  })
  expect(await band.find({ key: 'open-sessions' })).toBeUndefined()
  expect(await band.find({ key: 'engine-band' })).toBeDefined()
  await band.unmount()
})

test('the chord closes an open pane through its Hide button', async ($, on) => {
  const { panes } = world(on, {})
  await $.session.start({ cwd: ROOT, surface: 'terminal', isInteractive: true })
  await runSessions($)
  const ui = await $.ui.mount({
    plugin: 'clux',
    surface: 'terminal',
    component: 'Pane',
    requestId: 'sessions',
    props: PANE_PROPS,
  })
  expect((await ui.find({ key: 'close-sessions' }))?.props.action).toBe('app:cycleDiffBase')
  await ui.press({ key: 'close-sessions' })
  expect(panes.has('sessions')).toBe(false)
  await ui.unmount()
})
