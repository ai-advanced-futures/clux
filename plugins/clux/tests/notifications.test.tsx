import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On } from 'claude-code'

const ROOT = '/code/clux'
const QUEUE = '/home/me/.config/tmux/claude_notification'
const NOW = Date.parse('2026-10-08T09:00:00.000Z')
const IN_TMUX = { TMUX: '/tmp/tmux-1000/default,1,0' }

const WINDOW = 'main:editor Task done|||$sess1:@win3'
const AGENT = '⚡ agents / pr-flow|||agent:abc-123@@$s9:@w9:%pane3@@/code/clux'
const THIRD = 'main:tests 8/8 green|||$sess1:@win5'

const out = (stdout: string, exitCode = 0) => ({
  exitCode,
  stdout,
  stderr: '',
  isStdoutTruncated: false,
  isStderrTruncated: false,
})

// What the queue file holds; `null` is a file that is not there.
type Queue = { text: string | null }

// The world beneath the mod: the queue file, notification-line.sh, a host.
// The sessions pane loads from the same hooks module, so the calls it makes
// are answered here too.
function world(on: On, queue: Queue, env: Record<string, string> = {}) {
  const ran: string[][] = []
  const toasts: string[] = []
  const logs: string[] = []
  const closes: string[] = []
  const focuses: (string | undefined)[] = []
  // How notification-line.sh answers. `exits` and `rejects` are set by the
  // tests of the failure paths; by default every verb exits 0.
  const script = { exits: {} as Record<string, number>, rejects: new Set<string>() }
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/me', ...env })
  on('session.repo', () => ({ value: { root: ROOT, remote: null, internal: false, name: null } }))
  on('session.cwd', () => ({ value: ROOT }))
  on('session.id', () => ({ value: 'self' }))
  // The sessions pane reads ~/.claude/jobs: no background session here.
  on('fs.list', () => ({ value: [] }))
  on('fs.stat', ($, e) => ({
    value: { kind: 'dir' as const, size: 0, mtimeMs: 0, isLink: false, realPath: e.path },
  }))
  // Every read of the queue is counted, so a test can prove how many polls
  // one tick made.
  const reads = { count: 0 }
  on('fs.read', ($, e) => {
    if (e.path !== QUEUE) return { deny: 'ENOENT' }
    reads.count += 1
    if (queue.text === null) return { deny: 'ENOENT' }
    return { value: queue.text }
  })
  on('process.run', ($, e) => {
    ran.push([...e.argv])
    if (e.argv[0] === 'git') return { value: out('') }
    const verb = e.argv[1] ?? ''
    if (verb === 'path') return { value: out(`${QUEUE}\n`) }
    if (script.rejects.has(verb)) return { deny: 'spawn EACCES' }
    return { value: out('', script.exits[verb] ?? 0) }
  })
  on('ui.log', ($, e) => {
    logs.push(e.text)
    return { value: undefined }
  })
  on('ui.toast', ($, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  // The bottom of the focus chain: the ring moves where the hooks left it.
  on('ui.focus', ($, e) => {
    focuses.push(e.element)
    return {}
  })
  // The panes this plugin has open, as the engine would keep them.
  const panes = new Set<string>()
  on('ui.open', ($, e) => {
    panes.add(e.id)
    return { value: { isPlaced: true } }
  })
  on('ui.close', ($, e) => {
    panes.delete(e.id)
    closes.push(e.id)
    return { value: undefined }
  })
  on('ui.panes', () => ({
    value: [...panes].map(id => ({
      id, title: id, isShown: true, isFocused: true, isPlaced: true, plugin: 'clux',
    })),
  }))
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('ui.render', { component: 'SessionMode' }, ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    return (
      <Box key="engine-modes">
        <Text dimColor>{e.props.modes.join(' & ')}</Text>
      </Box>
    )
  })

  return { clock, ran, toasts, logs, closes, focuses, panes, queue, reads, script }
}

const PANE_PROPS = {
  title: 'Notifications',
  isFocused: false,
  bodyColumns: 80,
  placement: 'dock' as const,
  scroll: { offset: 0, bodyRows: 20 },
  view: {},
}

const mountPane = ($: Engine, isFocused = false) =>
  $.ui.mount({
    plugin: 'clux',
    surface: 'terminal',
    component: 'Pane',
    requestId: 'notifications',
    props: { ...PANE_PROPS, isFocused },
  })

const start = ($: Engine) =>
  $.session.start({ cwd: ROOT, surface: 'terminal', isInteractive: true })

// The verb and the line of each notification-line.sh run, in order. The one
// `path` run of the session start is left out.
const lineRuns = (ran: string[][]) =>
  ran
    .filter(argv => (argv[0] ?? '').endsWith('/scripts/notification-line.sh') && argv[1] !== 'path')
    .map(argv => [argv[1], argv[2]])

const rowLabels = async (ui: Awaited<ReturnType<typeof mountPane>>) =>
  (await ui.findAll({ type: 'Button' }))
    .filter(button => (button.key ?? '').startsWith('row:'))
    .map(button => String(button.props.label))

test('the pane draws one row for each line of the queue', async ($, on) => {
  world(on, { text: `${WINDOW}\n${AGENT}\n` })
  await start($)

  const ui = await mountPane($)
  const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text).join('\n')
  expect(texts).toContain('Notifications · 2')
  expect(await rowLabels(ui)).toEqual(['main:editor Task done', '⚡ agents / pr-flow'])
  expect((await ui.find({ key: 'row:0' }))?.props.autoFocus).toBe(true)
  expect((await ui.find({ key: 'row:1' }))?.props.autoFocus).toBeUndefined()
  await ui.unmount()
})

test('a queue file that is not there is an empty list', async ($, on) => {
  world(on, { text: null })
  await start($)

  const ui = await mountPane($)
  const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text).join('\n')
  expect(texts).toContain('Notifications · 0')
  expect(texts).toContain('No notifications.')
  expect(await ui.find({ key: 'row:0' })).toBeUndefined()
  await ui.unmount()
})

test('a pane without the keys says how to move into it', async ($, on) => {
  world(on, { text: `${WINDOW}\n` })
  await start($)
  const hint = 'ctrl+x tab: move into the list'

  const texts = async (isFocused: boolean) => {
    const ui = await mountPane($, isFocused)
    const all = (await ui.findAll({ type: 'Text' })).map(t => t.text).join('\n')
    await ui.unmount()
    return all
  }
  // A draft in the message box: Claude Code opens the pane without the keys.
  expect(await texts(false)).toContain(hint)
  expect((await texts(true)).includes(hint)).toBe(false)
})

test('Enter on a row jumps, takes the line out and closes the pane', async ($, on) => {
  const { ran, closes, queue } = world(on, { text: `${WINDOW}\n${AGENT}\n` }, IN_TMUX)
  await start($)
  const ui = await mountPane($, true)

  // The jump removes the line, so the next poll sees the shorter queue.
  queue.text = `${AGENT}\n`
  await ui.press({ key: 'row:0' })

  expect(lineRuns(ran)).toEqual([['jump', WINDOW], ['remove', WINDOW]])
  expect(closes).toEqual(['notifications'])
  expect(await rowLabels(ui)).toEqual(['⚡ agents / pr-flow'])
  await ui.unmount()
})

test('a run with no person at the prompt does not poll', async ($, on) => {
  const { clock, ran } = world(on, { text: `${WINDOW}\n` })
  await $.session.start({ cwd: ROOT, surface: null, isInteractive: false })
  await clock.advance(2000)
  await clock.settle()
  expect(ran.filter(argv => (argv[0] ?? '').endsWith('/scripts/notification-line.sh'))).toEqual([])
})

test('a start that runs twice keeps one timer', async ($, on) => {
  const { clock, reads } = world(on, { text: `${WINDOW}\n` })
  await start($)
  await start($)

  // Two live timers would read the queue twice in one tick.
  const before = reads.count
  await clock.advance(2000)
  await clock.settle()
  expect(reads.count - before).toBe(1)
})

test('a jump that exits 1 shows a toast, keeps the row and runs no remove', async ($, on) => {
  const { ran, toasts, closes, script } = world(on, { text: `${WINDOW}\n` }, IN_TMUX)
  await start($)
  script.exits.jump = 1
  const ui = await mountPane($, true)

  await ui.press({ key: 'row:0' })

  expect(lineRuns(ran)).toEqual([['jump', WINDOW]])
  expect(toasts).toEqual(['Could not jump to main:editor Task done.'])
  expect(closes).toEqual([])
  expect(await rowLabels(ui)).toEqual(['main:editor Task done'])
  await ui.unmount()
})

test('outside tmux Enter shows the toast and runs no script at all', async ($, on) => {
  const { ran, toasts, closes } = world(on, { text: `${WINDOW}\n` })
  await start($)
  const ui = await mountPane($, true)

  await ui.press({ key: 'row:0' })

  expect(lineRuns(ran)).toEqual([])
  expect(toasts).toEqual(['Could not jump to main:editor Task done.'])
  expect(closes).toEqual([])
  await ui.unmount()
})

test('a script that cannot start reads as exit 1, and says why in the debug log', async ($, on) => {
  const { toasts, logs, closes, script } = world(on, { text: `${WINDOW}\n` }, IN_TMUX)
  await start($)
  script.rejects.add('jump')
  const ui = await mountPane($, true)

  await ui.press({ key: 'row:0' })

  expect(toasts).toEqual(['Could not jump to main:editor Task done.'])
  expect(closes).toEqual([])
  expect(logs.some(line => line.includes('jump failed') && line.includes('EACCES'))).toBe(true)
  await ui.unmount()
})

test('a remove that cannot start reads as exit 1, keeps the row and says why in the debug log', async ($, on) => {
  const { toasts, logs, closes, script } = world(on, { text: `${WINDOW}\n` })
  await start($)
  script.rejects.add('remove')
  const ui = await mountPane($, true)

  await ui.press({ key: 'row-remove' })

  expect(toasts).toEqual(['The queue is busy. Try again.'])
  expect(closes).toEqual([])
  expect(await rowLabels(ui)).toEqual(['main:editor Task done'])
  expect(logs.some(line => line.includes('remove failed') && line.includes('EACCES'))).toBe(true)
  await ui.unmount()
})

// The row key of the last focus the mod asked for. `$.ui.focus` has no
// implementation beneath `claude plugin test` — it rejects with "no
// implementation for ui.focus", whatever the test registers — so every
// request is refused and the mod writes the key it asked for to the debug
// log. That the ring really moves is the live check of spec §6.0.
const lastFocusAsked = (logs: string[]) =>
  logs.filter(line => line.includes('the ring stayed off')).at(-1)?.match(/row:\d+/)?.[0]

const raiseFocus = ($: Engine, element?: string) =>
  $.ui.focus({
    component: 'Pane',
    requestId: 'notifications',
    element,
    origin: { kind: 'person' },
  })

test('the focus hook passes every move on, whatever takes the ring', async ($, on) => {
  const { focuses } = world(on, { text: `${WINDOW}\n${AGENT}\n${THIRD}\n` })
  await start($)
  const ui = await mountPane($, true)

  // A row, a header button, and one of the engine's own stops (no element).
  expect(await raiseFocus($, 'row:1')).toEqual({})
  expect(await raiseFocus($, 'nav-down')).toEqual({})
  expect(await raiseFocus($, undefined)).toEqual({})
  // A hook that does not call `next` would keep the ring where it was, and
  // Tab, the arrows, `j`, `k` and `x` would all move nothing.
  expect(focuses).toEqual(['row:1', 'nav-down', undefined])
  await ui.unmount()
})

test('j asks for the next row, and k stops at the first', async ($, on) => {
  const { logs } = world(on, { text: `${WINDOW}\n${AGENT}\n${THIRD}\n` })
  await start($)
  const ui = await mountPane($, true)

  expect((await ui.find({ key: 'nav-down' }))?.props.hotkey).toBe('j')
  expect((await ui.find({ key: 'nav-down' }))?.props.label).toBe('down')
  expect((await ui.find({ key: 'nav-up' }))?.props.hotkey).toBe('k')

  // The ring starts on the first row, so `j` asks for the second.
  await ui.press({ key: 'nav-down' })
  expect(lastFocusAsked(logs)).toBe('row:1')
  // The move was refused, so `focused` is still 0 and `k` stops there.
  await ui.press({ key: 'nav-up' })
  expect(lastFocusAsked(logs)).toBe('row:0')
  await ui.unmount()
})

test('j stops at the last row the list has', async ($, on) => {
  const { logs } = world(on, { text: `${WINDOW}\n${AGENT}\n${THIRD}\n` })
  await start($)
  const ui = await mountPane($, true)

  await raiseFocus($, 'row:2')
  await ui.press({ key: 'nav-down' })
  expect(lastFocusAsked(logs)).toBe('row:2')
  await ui.unmount()
})

test('j on an empty list asks for nothing', async ($, on) => {
  const { logs } = world(on, { text: null })
  await start($)
  const ui = await mountPane($, true)

  await ui.press({ key: 'nav-down' })
  expect(lastFocusAsked(logs)).toBeUndefined()
  await ui.unmount()
})

test('x takes the focused row out and polls again', async ($, on) => {
  const { ran, queue } = world(on, { text: `${WINDOW}\n${AGENT}\n` })
  await start($)
  const ui = await mountPane($, true)

  await raiseFocus($, 'row:1')
  queue.text = `${WINDOW}\n`
  await ui.press({ key: 'row-remove' })

  expect(lineRuns(ran)).toEqual([['remove', AGENT]])
  expect(await rowLabels(ui)).toEqual(['main:editor Task done'])
  await ui.unmount()
})

test('x with no focus before it takes the first row out', async ($, on) => {
  const { ran, queue } = world(on, { text: `${WINDOW}\n${AGENT}\n` })
  await start($)
  const ui = await mountPane($, true)

  queue.text = `${AGENT}\n`
  await ui.press({ key: 'row-remove' })

  expect(lineRuns(ran)).toEqual([['remove', WINDOW]])
  expect((await ui.find({ key: 'row-remove' }))?.props.hotkey).toBe('x')
  await ui.unmount()
})

test('x after a poll made the list shorter takes the last row out', async ($, on) => {
  const { ran, queue, clock } = world(on, { text: `${WINDOW}\n${AGENT}\n${THIRD}\n` })
  await start($)
  const ui = await mountPane($, true)

  await raiseFocus($, 'row:2')
  // The status bar took the top line while nobody pressed a key.
  queue.text = `${AGENT}\n${THIRD}\n`
  await clock.advance(2000)
  await clock.settle()
  queue.text = `${AGENT}\n`
  await ui.press({ key: 'row-remove' })

  expect(lineRuns(ran)).toEqual([['remove', THIRD]])
  await ui.unmount()
})

test('a busy queue says so and keeps the row', async ($, on) => {
  const { ran, toasts, script, queue } = world(on, { text: `${WINDOW}\n` })
  await start($)
  script.exits.remove = 1
  const ui = await mountPane($, true)

  await ui.press({ key: 'row-remove' })

  expect(lineRuns(ran)).toEqual([['remove', WINDOW]])
  expect(toasts).toEqual(['The queue is busy. Try again.'])
  expect(queue.text).toBe(`${WINDOW}\n`)
  expect(await rowLabels(ui)).toEqual(['main:editor Task done'])
  await ui.unmount()
})

test('x on an empty list runs nothing', async ($, on) => {
  const { ran } = world(on, { text: null })
  await start($)
  const ui = await mountPane($, true)

  await ui.press({ key: 'row-remove' })

  expect(lineRuns(ran)).toEqual([])
  await ui.unmount()
})

const runNotifications = ($: Engine, args = '') =>
  $.command.run({
    command: 'clux:notifications',
    args,
    origin: { kind: 'composer' },
    presentation: { isFullscreen: false, columns: 100 },
  })

test('/clux:notifications opens the pane, and /clux:notifications again closes it', async ($, on) => {
  const { panes } = world(on, { text: `${WINDOW}\n` })
  await start($)

  expect((await runNotifications($)).text).toContain('opened')
  expect(panes.has('notifications')).toBe(true)
  expect((await runNotifications($)).text).toContain('closed')
  expect(panes.has('notifications')).toBe(false)

  await runNotifications($, 'on')
  await runNotifications($, 'on')
  expect(panes.has('notifications')).toBe(true)
  await runNotifications($, 'off')
  expect(panes.has('notifications')).toBe(false)
})

test('opening the pane polls the queue first, and puts the ring on the first row', async ($, on) => {
  const { queue, logs } = world(on, { text: null })
  await start($)

  // A notification arrived between the last poll and the command.
  queue.text = `${WINDOW}\n${AGENT}\n`
  await runNotifications($, 'on')

  const ui = await mountPane($, true)
  expect(await rowLabels(ui)).toEqual(['main:editor Task done', '⚡ agents / pr-flow'])
  // The ring was put back on the first row, so `k` stays there.
  await ui.press({ key: 'nav-up' })
  expect(lastFocusAsked(logs)).toBe('row:0')
  await ui.unmount()
})

const FOOTER = {
  plugin: 'clux',
  surface: 'terminal' as const,
  component: 'SessionMode' as const,
}

test('the footer label counts the queue, and sits after the sessions label', async ($, on) => {
  const { clock, queue } = world(on, { text: `${WINDOW}\n${AGENT}\n${THIRD}\n` })
  await start($)

  const ui = await $.ui.mount({ ...FOOTER, props: { modes: ['focus'] } })
  const label = await ui.find({ key: 'open-notifications' })
  expect(label?.props.label).toBe('3 notifs')
  expect(label?.props.dimColor).toBe(false)
  // No chord: the label has no engine action to borrow.
  expect(label?.props.action).toBeUndefined()
  // The sessions label keeps the left of the footer.
  expect((await ui.findAll({ type: 'Button' })).map(button => button.key)).toEqual([
    'open-sessions',
    'open-notifications',
  ])
  await ui.unmount()

  queue.text = null
  await clock.advance(2000)
  await clock.settle()
  const quiet = await $.ui.mount({ ...FOOTER, props: { modes: [] } })
  const quietLabel = await quiet.find({ key: 'open-notifications' })
  expect(quietLabel?.props.label).toBe('notifs')
  expect(quietLabel?.props.dimColor).toBe(true)
  await quiet.unmount()
})

test('a click on the footer label opens the pane', async ($, on) => {
  const { panes } = world(on, { text: `${WINDOW}\n` })
  await start($)

  const ui = await $.ui.mount({ ...FOOTER, props: { modes: [] } })
  await ui.press({ key: 'open-notifications' })
  expect(panes.has('notifications')).toBe(true)
  await ui.unmount()
})
