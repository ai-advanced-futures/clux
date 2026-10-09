import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, Timer } from 'claude-code'

import type { NotifRow } from '../../types'
import { toRows } from './lines'

const PANE = 'notifications'
const TITLE = 'Notifications'
// commands/notifications.md declares it; the hook below answers it.
const COMMAND = 'clux:notifications'
// The chord that toggles the pane, also with a draft in the composer. No
// engine action runs a plugin command, so the mod borrows this one, as the
// sessions pane borrows app:cycleDiffBase. It has no default key: the person
// binds one in ~/.claude/keybindings.json (clux suggests "ctrl+x n").
const TOGGLE_ACTION = 'app:toggleDiffPreSession'
// The status bar of tmux shows a new notification sooner, on its own
// interval; this is one file read.
const POLL_MS = 2000

const notifications = atom({ plugin: 'clux', key: 'notifications' } as const, [])

// The poll loop of this session: the queue path, read one time at the start.
const loop: { queue?: string; timer?: Timer; isPolling: boolean } = { isPolling: false }

// The plugin's own copy of the script, so the pane works from `--plugin-dir`
// with no /clux:setup. The tmux keys run the copy in ~/.config/clux/scripts/.
const script = ($: EngineInterface) => `${$.plugin.root}/scripts/notification-line.sh`

// One source for the queue path: the script resolves the three tiers.
async function queuePath($: EngineInterface): Promise<string> {
  const answer = await $.process.run([script($), 'path']).catch(() => undefined)
  const path = answer?.exitCode === 0 ? answer.stdout.trim() : ''
  if (path !== '') return path
  return `${await $.env.get('HOME')}/.config/tmux/claude_notification`
}

// A missing queue file is an empty list. The poll takes no lock: a writer can
// leave the file empty for a moment, and the next poll draws the right list.
async function poll($: EngineInterface) {
  const queue = loop.queue
  if (!queue) return
  const text = await $.fs.read(queue).catch(() => '')
  const list = toRows(typeof text === 'string' ? text : '')
  const before = await read($, notifications)
  if (JSON.stringify(list) !== JSON.stringify(before)) {
    await update($, notifications, () => list)
  }
}

// One poll at a time, so a slow poll and the next tick never overlap.
async function tick($: EngineInterface) {
  if (loop.isPolling) return
  loop.isPolling = true
  try {
    await poll($)
  } catch (error) {
    $.ui.log(`clux notifications: poll failed: ${String(error)}`, { to: 'debug' })
  } finally {
    loop.isPolling = false
  }
}

// The row the ring sits on. The `ui.focus` hook below and `focusRow` write it,
// apart from `openPane`, which puts it back on the first row when the pane
// opens new.
let focused = 0

// Asked (a command, a press) it seats at any width; `focus` hands it the
// keys. A pane that opens new puts the ring on the first row, so `focused`
// goes back to 0. A pane that is already open keeps its ring where the
// person put it, so `focused` keeps its value too: a reset there would make
// `x` remove the first row while the ring shows another.
async function openPane($: EngineInterface) {
  const isOpen = (await $.ui.panes()).some(pane => pane.id === PANE)
  if (!isOpen) focused = 0
  await tick($)
  return $.ui.open({ id: PANE, title: TITLE, focus: true })
}

// One verb of the shared script on one line. A script that cannot start, or
// that overruns its budget, reads as a failure exactly as a non-zero exit
// does; the reason goes to the debug log, never to the person.
async function runLine($: EngineInterface, verb: 'jump' | 'remove', row: NotifRow) {
  const answer = await $.process.run([script($), verb, row.line]).catch(error => {
    $.ui.log(`clux notifications: ${verb} failed: ${String(error)}`, { to: 'debug' })
    return undefined
  })
  return answer?.exitCode === 0
}

// Enter on a row. The jump leaves tmux on another window, so the pane closes:
// a pane that stays open shows the list of the window the person just left.
// The remove is needed because the status bar removes only the top line. An
// agent line needs no remove: the jump of an agent line removes it.
//
// The script runs also when Claude Code is not in tmux (a background
// session has no TMUX): with no current client, tmux moves the client it
// picks itself. With no tmux server, the script exits 1, the pane and the row
// both stay, and the person can still press `x`.
async function jumpTo($: EngineInterface, row: NotifRow) {
  if (!(await runLine($, 'jump', row))) {
    $.ui.toast(`Could not jump to ${row.text}.`)
    return
  }
  if (row.kind === 'window') await runLine($, 'remove', row)
  await $.ui.close({ id: PANE })
  await tick($)
}

// Move the ring. The pane may not hold the keys, and then the engine refuses
// the move: the person sees nothing, `focused` keeps its value, and the
// reason goes to the debug log. `j`, `k` and `x` all follow this rule.
//
// A move that lands sets `focused` here. The engine does not give a plugin's
// own `$.ui.focus` to that plugin's `ui.focus` hook (the debug log says
// "ui.focus skipped: re-entry"), so the hook below never sees it.
async function focusRow($: EngineInterface, index: number) {
  const key = `row:${index}`
  const moved = await $.ui
    .focus({ requestId: PANE, key })
    .catch(error => ({ deny: String(error) }))
  if (moved.deny) {
    $.ui.log(`clux notifications: the ring stayed off ${key}: ${moved.deny}`, { to: 'debug' })
    return
  }
  focused = index
}

// `j` and `k`: one row on, limited to the list. A poll can make the list
// shorter with no key press, so the upper limit is read from the list the
// last poll wrote.
async function move($: EngineInterface, by: number) {
  const list = await read($, notifications)
  if (list.length === 0) return
  await focusRow($, Math.min(list.length - 1, Math.max(0, focused + by)))
}

// `x`: the queue keeps a notification until the person has read it somewhere
// else, so this is the way to drop one from the pane. The index is limited
// to the list the last poll wrote, the same limit `j` and `k` use, because a
// poll can make the list shorter with no key press.
async function removeRow($: EngineInterface) {
  const list = await read($, notifications)
  if (list.length === 0) return
  const row = list[Math.min(focused, list.length - 1)]
  if (!row) return
  if (!(await runLine($, 'remove', row))) {
    $.ui.toast('The queue is busy. Try again.')
    return
  }
  await tick($)
  const after = await read($, notifications)
  // The ring stays at the same place, so taking the last row out moves it up
  // one. An empty list draws "No notifications." and has no row key at all.
  if (after.length > 0) await focusRow($, Math.min(focused, after.length - 1))
}

export const register: Register = on => {
  // The matcher does two jobs. A `-p` run or the SDK has no person at the
  // prompt and no pane to show; and the sessions pane already registers
  // `session.start` with no matcher, and two unmatched hooks on one event in
  // one module are refused by the engine.
  on('session.start', { isInteractive: true }, async ($, e, next) => {
    try {
      loop.queue = await queuePath($)
      await tick($)
      loop.timer?.cancel()
      loop.timer = $.clock.every(POLL_MS, () => void tick($))
    } catch (error) {
      $.ui.log(`clux notifications: start failed: ${String(error)}`, { to: 'debug' })
    }

    return next(e)
  })

  // `/clux:notifications` alone toggles the pane: it closes a pane that
  // shows, and opens one that is closed or a tab behind another. `on` and
  // `off` set it.
  on('command.run', { command: COMMAND }, async ($, e) => {
    const arg = e.args.trim()
    const isShown = (await $.ui.panes()).some(pane => pane.id === PANE && pane.isShown)
    if (arg === 'off' || (arg !== 'on' && isShown)) {
      await $.ui.close({ id: PANE })
      return { text: 'Notifications pane closed.' }
    }
    await openPane($)

    return { text: 'Notifications pane opened. Press Enter to go to a notification, or x to remove it.' }
  }).catch(($, e, next) => {
    $.ui.log(`clux notifications: command failed: ${String(next.error)}`, { to: 'debug' })
    return { text: 'The notifications pane did not respond. Try the command again.' }
  })

  // The ring records the row it lands on, then moves on: a `ui.focus` hook
  // that does not call `next` keeps the ring where it was, so Tab, the
  // arrows, `j`, `k` and `x` would all move nothing. A header button, or one
  // of the engine's own stops (the close mark, with no `element`), leaves
  // `focused` as it was, so `x` still acts on the row last focused.
  on('ui.focus', { requestId: PANE }, async ($, e, next) => {
    const key = e.element ?? ''
    if (key.startsWith('row:')) {
      const index = Number(key.slice(4))
      if (Number.isInteger(index) && index >= 0) focused = index
    }

    return next(e)
  }).catch(($, e, next) => (next.called ? {} : next(e)))

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const list = await read($, notifications)
    // The row text is cut to the pane, so one long notification cannot
    // reflow the list.
    const width = Math.max(8, e.props.bodyColumns - 1)

    return (
      <Box flexDirection="column">
        <Box>
          <Text bold>{TITLE} · {list.length} </Text>
          {/* Over the footer's label: the chord closes an open pane, and `q`
              closes it while the pane has the keys. Plain, so it reads
              "q: hide", as the other keys do. */}
          <Button
            key="close-notifications"
            plain
            hotkey="q"
            label="hide"
            action={TOGGLE_ACTION}
            onPress={() => $.ui.close({ id: PANE })}
          />
          <Text> </Text>
          {/* Claude Code draws a plain Button with a hotkey as "j: down". */}
          <Button key="nav-down" plain hotkey="j" label="down" onPress={() => move($, 1)} />
          <Text> </Text>
          <Button key="nav-up" plain hotkey="k" label="up" onPress={() => move($, -1)} />
          <Text> </Text>
          <Button key="row-remove" plain hotkey="x" label="remove" onPress={() => removeRow($)} />
        </Box>
        {/* Claude Code opens a pane without the keys while the message box
            has a draft, and a mod cannot take them: the person moves in. */}
        {!e.props.isFocused && list.length > 0 && (
          <Text dimColor>ctrl+x tab: move into the list</Text>
        )}
        {list.length === 0 && <Text dimColor>No notifications.</Text>}
        {list.map((row, i) => (
          <Button
            key={`row:${i}`}
            autoFocus={i === 0 ? true : undefined}
            plain
            label={row.text.slice(0, width)}
            onPress={() => jumpTo($, row)}
          />
        ))}
      </Box>
    )
  })

  // No band: one label at the end of the prompt footer, so a click opens the
  // pane while it is closed, and the chord has a Button to press. It is dim
  // until the queue has something in it.
  //
  // `next(e)` draws first, so the sessions label stays on the left. The
  // separator needs no condition: the sessions hook always draws its own
  // label, so `next(e)` is never empty.
  on('ui.render', { component: 'SessionMode' }, async ($, e, next) => {
    const list = await read($, notifications)
    const { Box, Text, Button } = $.ui.resolve(e)

    return (
      <Box>
        {await next(e)}
        <Text dimColor> & </Text>
        <Button
          key="open-notifications"
          plain
          dimColor={list.length === 0}
          label={list.length > 0 ? `${list.length} notifs` : 'notifs'}
          action={TOGGLE_ACTION}
          onPress={() => openPane($)}
        />
      </Box>
    )
  })
}
