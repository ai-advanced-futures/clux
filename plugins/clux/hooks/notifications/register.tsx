import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, Timer } from 'claude-code'

import type { FilterEditing, FilterRow, NotifRow } from '../../types'
import { editValue, parseList, rowText, splitRule, validCount } from './filters'
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
// The Filters view: which view shows, the filter file of the session's repo,
// its rules, and the rule box. The notifications atom does not change.
const filters = atom({ plugin: 'clux', key: 'filters' } as const, {
  view: 'notifications',
  file: '',
  rules: [],
  editing: null,
})

// The poll loop of this session: the queue path, read one time at the start.
const loop: { queue?: string; timer?: Timer; isPolling: boolean } = { isPolling: false }

// The plugin's own copy of the script, so the pane works from `--plugin-dir`
// with no /clux:setup. The tmux keys run the copy in ~/.config/clux/scripts/.
const script = ($: EngineInterface) => `${$.plugin.root}/scripts/notification-line.sh`
// The filter file has one owner, as the queue line has: the hook, the status
// bar and this pane all run notify-filter.sh, so the pane parses no rule and
// checks no regex itself.
const filterScript = ($: EngineInterface) => `${$.plugin.root}/scripts/notify-filter.sh`

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

// One verb of notify-filter.sh on the session cwd, through runScript.
async function runFilter($: EngineInterface, verb: string, args: string[] = []) {
  const cwd = await $.session.cwd()
  return runScript($, [filterScript($), verb, cwd, ...args], `filter ${verb}`)
}

// The filter file path, read one time at the start. '' when the cwd is not in
// a git repo: then the pane polls no list.
async function filterPath($: EngineInterface): Promise<string> {
  const answer = await runFilter($, 'path')
  return answer?.exitCode === 0 ? answer.stdout.trim() : ''
}

// The rules, in both views: the header counts them. A list that fails keeps
// the rows the last poll drew.
async function pollFilters($: EngineInterface) {
  const state = await read($, filters)
  if (state.file === '') return
  const answer = await runFilter($, 'list')
  if (answer?.exitCode !== 0) return
  const rules = parseList(answer.stdout)
  if (JSON.stringify(rules) !== JSON.stringify(state.rules)) {
    await update($, filters, s => ({ ...s, rules }))
  }
}

// One poll at a time, so a slow poll and the next tick never overlap.
async function tick($: EngineInterface) {
  if (loop.isPolling) return
  loop.isPolling = true
  try {
    await poll($)
    await pollFilters($)
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

// A script that cannot start, or that overruns its budget, resolves to
// undefined, and so reads as a failure exactly as a non-zero exit does; the
// reason goes to the debug log, never to the person. The budget is RUN_MS:
// the engine default is 30 s, too long for a key press when tmux does not
// answer.
const RUN_MS = 5000

async function runScript($: EngineInterface, argv: string[], label: string) {
  return $.process.run(argv, { timeoutMs: RUN_MS }).catch(error => {
    $.ui.log(`clux notifications: ${label} failed: ${String(error)}`, { to: 'debug' })
    return undefined
  })
}

// One verb of the shared script on one line.
async function runLine($: EngineInterface, verb: 'jump' | 'remove', row: NotifRow) {
  const answer = await runScript($, [script($), verb, row.line], verb)
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
  // The jump is done, so the pane closes also when the remove fails; the
  // person learns that the row stays in the queue.
  if (row.kind === 'window' && !(await runLine($, 'remove', row))) {
    $.ui.toast('The queue is busy. The notification stays in the queue.')
  }
  await $.ui.close({ id: PANE })
  await tick($)
}

// Move the ring. The pane may not hold the keys, and then the engine refuses
// the move: the person sees nothing, the index keeps its value, and the
// reason goes to the debug log. `j`, `k` and `x` all follow this rule, in
// both views.
//
// A move that lands sets the index there. The engine does not give a
// plugin's own `$.ui.focus` to that plugin's `ui.focus` hook (the debug log
// says "ui.focus skipped: re-entry"), so the hook below never sees it.
async function askFocus($: EngineInterface, key: string): Promise<boolean> {
  const moved = await $.ui
    .focus({ requestId: PANE, key })
    .catch(error => ({ deny: String(error) }))
  if (moved.deny) {
    $.ui.log(`clux notifications: the ring stayed off ${key}: ${moved.deny}`, { to: 'debug' })
    return false
  }
  return true
}

async function focusRow($: EngineInterface, index: number) {
  if (await askFocus($, `row:${index}`)) focused = index
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

// --- The Filters view -------------------------------------------------------

// The row the ring sits on in the Filters view: its own index and its own
// key prefix, `rule:<i>`, so the two views never move each other's ring.
let ruleFocused = 0

// The key of the rule box, and the toasts of a rule the pane refuses.
const INPUT_KEY = 'filter-input'
const BAD_KIND = 'A rule starts with allow or deny.'
const STALE = 'The file changed. Try again.'

// `f` and `n`. A view opens with its ring on its first row, and the rule box
// closes.
async function showView($: EngineInterface, view: 'notifications' | 'filters') {
  await update($, filters, s => ({ ...s, view, editing: null }))
  if (view === 'filters') {
    ruleFocused = 0
    if ((await read($, filters)).rules.length > 0) await askFocus($, 'rule:0')
  } else {
    focused = 0
    if ((await read($, notifications)).length > 0) await askFocus($, 'row:0')
  }
}

async function focusRule($: EngineInterface, index: number) {
  if (await askFocus($, `rule:${index}`)) ruleFocused = index
}

// `j` and `k` in the Filters view, limited to the rows the last poll wrote.
async function moveRule($: EngineInterface, by: number) {
  const { rules } = await read($, filters)
  if (rules.length === 0) return
  await focusRule($, Math.min(rules.length - 1, Math.max(0, ruleFocused + by)))
}

// The focused rule, limited to the list the last poll wrote.
async function focusedRule($: EngineInterface): Promise<FilterRow | undefined> {
  const { rules } = await read($, filters)
  if (rules.length === 0) return undefined
  return rules[Math.min(ruleFocused, rules.length - 1)]
}

// What an answer of add, set or remove means for the person. 0 'ok': the
// file changed, so the list is read again. 2 'refused': the script refused
// the rule, and the first line of its stderr says why. 3 'stale': the line
// moved under the pane, so the list is read again. Only this function reads
// the exit codes.
async function settle(
  $: EngineInterface,
  answer: Awaited<ReturnType<typeof runFilter>>,
): Promise<'ok' | 'stale' | 'refused' | 'failed'> {
  if (answer?.exitCode === 0) {
    await pollFilters($)
    return 'ok'
  }
  if (answer?.exitCode === 3) {
    await pollFilters($)
    $.ui.toast(STALE)
    return 'stale'
  }
  if (answer?.exitCode === 2) {
    $.ui.toast(answer.stderr.split('\n')[0]?.trim() || 'The rule was not saved.')
    return 'refused'
  }
  $.ui.toast('The filter file did not change.')
  return 'failed'
}

// The rule box takes the keys. In a test, and while the pane does not hold
// the keys, the engine refuses: the box is drawn all the same.
async function openBox($: EngineInterface, editing: NonNullable<FilterEditing>) {
  await update($, filters, s => ({ ...s, editing }))
  await askFocus($, INPUT_KEY)
}

// `a`: a new rule, `deny ` ready in the box.
async function addRule($: EngineInterface) {
  await openBox($, { mode: 'add', value: 'deny ' })
}

// `e`, or Enter on a row: the box holds the rule, to replace its line.
async function editRule($: EngineInterface, index?: number) {
  if (index !== undefined) ruleFocused = index
  const row = await focusedRule($)
  if (!row) return
  await openBox($, { mode: 'set', n: row.n, value: editValue(row) })
}

// Enter in the box. A refused rule keeps the box open with what the person
// typed; a stale line closes it, because its line number is no longer true.
async function submitRule($: EngineInterface, value: string) {
  const { editing } = await read($, filters)
  if (!editing) return
  const keep = () => update($, filters, s => ({ ...s, editing: { ...editing, value } }))
  const rule = splitRule(value)
  if (!rule) {
    $.ui.toast(BAD_KIND)
    await keep()
    return
  }
  const answer = editing.mode === 'add'
    ? await runFilter($, 'add', [rule.kind, rule.regex])
    : await runFilter($, 'set', [String(editing.n), rule.kind, rule.regex])
  const outcome = await settle($, answer)
  if (outcome === 'ok' || outcome === 'stale') {
    await update($, filters, s => ({ ...s, editing: null }))
    return
  }
  await keep()
}

// `t`: allow becomes deny and deny becomes allow, with the same regex. An
// invalid row has no kind to change: `e` mends it.
async function toggleRule($: EngineInterface) {
  const row = await focusedRule($)
  if (!row || row.kind === 'invalid') return
  await settle($, await runFilter($, 'set', [String(row.n), row.kind === 'allow' ? 'deny' : 'allow', row.text]))
}

// `x`: the focused line goes. The ring stays at the same place, so taking
// the last row out moves it up one.
async function removeRule($: EngineInterface) {
  const row = await focusedRule($)
  if (!row) return
  if ((await settle($, await runFilter($, 'remove', [String(row.n)]))) !== 'ok') return
  const { rules } = await read($, filters)
  if (rules.length > 0) await focusRule($, Math.min(ruleFocused, rules.length - 1))
}

// The row index in a ring key such as `row:3`, or undefined for another key.
function indexAfter(key: string, prefix: string): number | undefined {
  if (!key.startsWith(prefix)) return undefined
  const index = Number(key.slice(prefix.length))
  return Number.isInteger(index) && index >= 0 ? index : undefined
}

export const register: Register = on => {
  // The matcher does two jobs. A `-p` run or the SDK has no person at the
  // prompt and no pane to show; and the sessions pane already registers
  // `session.start` with no matcher, and two unmatched hooks on one event in
  // one module are refused by the engine.
  on('session.start', { isInteractive: true }, async ($, e, next) => {
    try {
      loop.queue = await queuePath($)
      const file = await filterPath($)
      await update($, filters, s => ({ ...s, file }))
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
  //
  // The rule box closes when the ring leaves it: Esc gives the keys back to
  // the ring, and a box the person left holds no edit they can see through.
  on('ui.focus', { requestId: PANE }, async ($, e, next) => {
    const key = e.element ?? ''
    focused = indexAfter(key, 'row:') ?? focused
    ruleFocused = indexAfter(key, 'rule:') ?? ruleFocused
    if (key !== INPUT_KEY && (await read($, filters)).editing) {
      await update($, filters, s => ({ ...s, editing: null }))
    }

    return next(e)
  }).catch(($, e, next) => (next.called ? {} : next(e)))

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const elements = $.ui.resolve(e)
    const { Box, Text, Button } = elements
    // The mobile surface draws no Input: there the rule box is not drawn,
    // and the rules are read only.
    const Input = 'Input' in elements ? elements.Input : undefined
    const list = await read($, notifications)
    const state = await read($, filters)
    const isFilters = state.view === 'filters'
    const hasRepo = state.file !== ''
    // The row text is cut to the pane, so one long notification cannot
    // reflow the list.
    const width = Math.max(8, e.props.bodyColumns - 1)

    return (
      <Box flexDirection="column">
        <Box>
          {/* The two views, the one that shows in bold. */}
          <Text bold={!isFilters}>{TITLE} · {list.length}</Text>
          <Text>  |  </Text>
          <Text bold={isFilters}>Filters · {validCount(state.rules)} </Text>
          {/* Over the footer's label: the chord closes an open pane, and `q`
              closes it while the pane has the keys. Plain, so it reads
              "q: hide", as the other keys do. Both views draw it. */}
          <Button
            key="close-notifications"
            plain
            hotkey="q"
            label="hide"
            action={TOGGLE_ACTION}
            onPress={() => $.ui.close({ id: PANE })}
          />
          {/* Only the keys of the view that shows: a hotkey of the other
              view would act on rows the person cannot see. */}
          {!isFilters && (
            <Box key="notification-keys">
              <Text> </Text>
              {/* Claude Code draws a plain Button with a hotkey as "j: down". */}
              <Button key="nav-down" plain hotkey="j" label="down" onPress={() => move($, 1)} />
              <Text> </Text>
              <Button key="nav-up" plain hotkey="k" label="up" onPress={() => move($, -1)} />
              <Text> </Text>
              <Button key="row-remove" plain hotkey="x" label="remove" onPress={() => removeRow($)} />
              <Text> </Text>
              <Button key="view-filters" plain hotkey="f" label="filters" onPress={() => showView($, 'filters')} />
            </Box>
          )}
          {isFilters && (
            <Box key="filter-keys">
              <Text> </Text>
              <Button key="view-notifications" plain hotkey="n" label="notifications" onPress={() => showView($, 'notifications')} />
              {hasRepo && (
                <Box key="rule-keys">
                  <Text> </Text>
                  <Button key="rule-down" plain hotkey="j" label="down" onPress={() => moveRule($, 1)} />
                  <Text> </Text>
                  <Button key="rule-up" plain hotkey="k" label="up" onPress={() => moveRule($, -1)} />
                  <Text> </Text>
                  <Button key="rule-add" plain hotkey="a" label="add" onPress={() => addRule($)} />
                  <Text> </Text>
                  <Button key="rule-edit" plain hotkey="e" label="edit" onPress={() => editRule($)} />
                  <Text> </Text>
                  <Button key="rule-toggle" plain hotkey="t" label="allow/deny" onPress={() => toggleRule($)} />
                  <Text> </Text>
                  <Button key="rule-remove" plain hotkey="x" label="remove" onPress={() => removeRule($)} />
                </Box>
              )}
            </Box>
          )}
        </Box>
        {/* Claude Code opens a pane without the keys while the message box
            has a draft, and a mod cannot take them: the person moves in. */}
        {!e.props.isFocused && !isFilters && list.length > 0 && (
          <Text dimColor>ctrl+x tab: move into the list</Text>
        )}
        {!isFilters && list.length === 0 && <Text dimColor>No notifications.</Text>}
        {!isFilters && list.map((row, i) => (
          <Button
            key={`row:${i}`}
            autoFocus={i === 0 ? true : undefined}
            plain
            label={row.text.slice(0, width)}
            onPress={() => jumpTo($, row)}
          />
        ))}
        {isFilters && !hasRepo && <Text dimColor>Not in a git repo.</Text>}
        {isFilters && hasRepo && <Text dimColor>{state.file.slice(0, width)}</Text>}
        {isFilters && hasRepo && state.rules.length === 0 && (
          <Text dimColor>No filters. a: add a rule.</Text>
        )}
        {/* A Button draws no color of its own, so an invalid row is a red
            word before its raw line. Enter on a row edits it. */}
        {isFilters && hasRepo && state.rules.map((row, i) => (
          <Box key={`rule-line:${i}`}>
            {row.kind === 'invalid' && <Text color="red">invalid </Text>}
            <Button
              key={`rule:${i}`}
              autoFocus={i === 0 && !state.editing ? true : undefined}
              plain
              label={rowText(row).slice(0, width)}
              onPress={() => editRule($, i)}
            />
          </Box>
        ))}
        {isFilters && hasRepo && state.editing && Input && (
          <Input
            key={INPUT_KEY}
            label={state.editing.mode === 'add' ? 'new rule: ' : `line ${state.editing.n}: `}
            placeholder="allow|deny <regex>"
            value={state.editing.value}
            submitLabel="save"
            onSubmit={(value: string) => submitRule($, value)}
          />
        )}
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
