import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, Timer } from 'claude-code'

import type { BgSession, BgStatus } from '../../types'
import {
  LABEL,
  isFresh,
  mentionText,
  sortSessions,
  toSession,
  worktreePaths,
} from './jobs'

const PANE = 'sessions'
// commands/sessions.md declares it; the hook below answers it.
const COMMAND = 'clux:sessions'
// The chord that toggles the pane, also with a draft in the composer. No
// engine action runs a plugin command, so the mod borrows this one: its
// engine handler is mounted only in the diff panel, where it keeps its job.
const TOGGLE_ACTION = 'app:cycleDiffBase'
const TITLE = 'Background sessions'
const POLL_MS = 5000
// Read the worktree list again after this many polls (one minute).
const ROOTS_EVERY = 12

const sessions = atom({ plugin: 'clux', key: 'sessions' } as const, [])

const COLOR: Record<BgStatus, string> = {
  'needs-input': 'warning',
  working: 'suggestion',
  unknown: 'inactive',
  done: 'success',
  failed: 'error',
  stopped: 'inactive',
}

// What a poll needs. Only `roots` changes, when a worktree is added.
type Scope = { dir: string; roots: string[]; selfId: string }

async function jobsDir($: EngineInterface): Promise<string> {
  const config = await $.env.get('CLAUDE_CONFIG_DIR')
  if (config) return `${config}/jobs`
  return `${await $.env.get('HOME')}/.claude/jobs`
}

// The main working tree and every worktree of the repository, also a
// worktree outside the main tree; the session's folder outside git. Each
// root also as the path it lands on, for a root behind a symbolic link.
async function repoRoots($: EngineInterface): Promise<string[]> {
  const repo = await $.session.repo().catch(() => null)
  let paths = [await $.session.cwd()]
  if (repo) {
    const listed = await $.process
      .run(['git', '-C', repo.root, 'worktree', 'list', '--porcelain'])
      .catch(() => undefined)
    paths = [repo.root, ...(listed?.exitCode === 0 ? worktreePaths(listed.stdout) : [])]
  }
  const real = await Promise.all(
    paths.map(path =>
      $.fs.stat(path, { resolve: true }).then(stat => stat.realPath, () => undefined),
    ),
  )
  return [...new Set([...paths, ...real.filter((path): path is string => !!path)])]
}

async function readSessions($: EngineInterface, scope: Scope, now: number) {
  const entries = await $.fs.list(scope.dir).catch(() => [])
  const texts = await Promise.all(
    entries
      .filter(entry => entry.kind === 'dir')
      .map(async entry => ({
        id: entry.name,
        text: await $.fs.read(`${scope.dir}/${entry.name}/state.json`).catch(() => ''),
      })),
  )
  const found = texts.flatMap(({ id, text }) => {
    if (typeof text !== 'string' || text === '') return []
    const session = toSession(id, text, scope.roots, scope.selfId, now)
    return session && isFresh(session, now) ? [session] : []
  })

  return sortSessions(found)
}

async function poll($: EngineInterface, scope: Scope) {
  const now = await $.clock.now()
  const list = await readSessions($, scope, now)
  const before = await read($, sessions)
  if (JSON.stringify(list) !== JSON.stringify(before)) {
    await update($, sessions, () => list)
  }
}

// Asked (a command, a press) it seats at any width; `focus` hands it the keys.
function openPane($: EngineInterface) {
  return $.ui.open({ id: PANE, title: TITLE, focus: true })
}

// Selecting a session puts its @name in the message box at the cursor. The
// pane closes first, so the keys go back to the box for the next word.
async function mention($: EngineInterface, session: BgSession) {
  const { text, cursor } = await $.prompt.read()
  const handle = mentionText(session.name, text.slice(0, cursor))
  await $.ui.close({ id: PANE })
  const filled = await $.prompt.fill({ text: handle, mode: 'insert' }).catch(() => undefined)
  if (!filled?.isFilled) $.ui.toast(`Could not put @${session.name} in the message box.`)
}

const countNeeds = (list: readonly BgSession[]) =>
  list.filter(s => s.status === 'needs-input').length

// The poll loop of this session: set at the start, read by each tick.
const loop: { scope?: Scope; timer?: Timer; isPolling: boolean; polls: number } = {
  isPolling: false,
  polls: 0,
}

// One poll at a time, so a slow poll and the next tick never overlap.
async function tick($: EngineInterface) {
  const scope = loop.scope
  if (!scope || loop.isPolling) return
  loop.isPolling = true
  try {
    loop.polls += 1
    if (loop.polls % ROOTS_EVERY === 0) scope.roots = await repoRoots($)
    await poll($, scope)
  } catch (error) {
    $.ui.log(`clux sessions: poll failed: ${String(error)}`, { to: 'debug' })
  } finally {
    loop.isPolling = false
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    // A `-p` run or the SDK has no person at the prompt and no pane to show.
    if (!e.isInteractive) return next(e)
    try {
      loop.scope = {
        dir: await jobsDir($),
        roots: await repoRoots($),
        selfId: await $.session.id(),
      }
      await tick($)
      loop.timer?.cancel()
      loop.timer = $.clock.every(POLL_MS, () => void tick($))
    } catch (error) {
      $.ui.log(`clux sessions: start failed: ${String(error)}`, { to: 'debug' })
    }

    return next(e)
  })

  // `/clux:sessions` alone toggles the pane: it closes a pane that shows, and
  // opens one that is closed or a tab behind another. `on` and `off` set it.
  on('command.run', { command: COMMAND }, async ($, e) => {
    const arg = e.args.trim()
    const isShown = (await $.ui.panes()).some(pane => pane.id === PANE && pane.isShown)
    if (arg === 'off' || (arg !== 'on' && isShown)) {
      await $.ui.close({ id: PANE })
      return { text: 'Background sessions pane closed.' }
    }
    await tick($)
    await openPane($)

    return { text: 'Background sessions pane opened. Press Enter or a number to put a session in the message box.' }
  }).catch(($, e, next) => {
    $.ui.log(`clux sessions: command failed: ${String(next.error)}`, { to: 'debug' })
    return { text: 'The background sessions pane did not respond. Try the command again.' }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button, Link } = $.ui.resolve(e)
    const list = await read($, sessions)
    const nameWidth = Math.min(28, Math.max(8, ...list.map(s => s.name.length)))

    return (
      <Box flexDirection="column">
        <Box>
          <Text bold>{TITLE} · {list.length} </Text>
          {/* Over the footer's label: the chord closes an open pane. */}
          <Button
            key="close-sessions"
            label="Hide"
            action={TOGGLE_ACTION}
            onPress={() => $.ui.close({ id: PANE })}
          />
        </Box>
        {list.length === 0 && (
          <Text dimColor>No background sessions for this repository.</Text>
        )}
        {list.map((s, i) => (
          // Name, status and PRs keep their width; the description is cut.
          <Box key={`row-${s.id}`}>
            <Box flexShrink={0}>
              <Button
                key={`mention-${s.id}`}
                autoFocus={i === 0 ? true : undefined}
                plain
                hotkey={i < 9 ? String(i + 1) : undefined}
                label={s.name.slice(0, nameWidth).padEnd(nameWidth)}
                onPress={() => mention($, s)}
              />
              <Text color={COLOR[s.status]}> ● {LABEL[s.status].padEnd(12)}</Text>
              {s.prs.map(pr => (
                <Link key={`pr-${s.id}-${pr.id}`} href={pr.href} label={`#${pr.id} `} />
              ))}
            </Box>
            <Box flexShrink={1} minWidth={0}>
              <Text dimColor wrap="truncate-end">{s.line}</Text>
            </Box>
          </Box>
        ))}
      </Box>
    )
  })

  // No band: one label at the end of the prompt footer, so the chord has a
  // Button to press while the pane is closed. It is dim until a question waits.
  on('ui.render', { component: 'SessionMode' }, async ($, e, next) => {
    const needs = countNeeds(await read($, sessions))
    const { Box, Text, Button } = $.ui.resolve(e)

    // The footer is one instance: draw what the hooks below draw, then this.
    return (
      <Box>
        {await next(e)}
        {e.props.modes.length > 0 && <Text dimColor> & </Text>}
        <Button
          key="open-sessions"
          plain
          dimColor={needs === 0}
          label={needs > 0 ? `${needs} needs input` : 'sessions'}
          action={TOGGLE_ACTION}
          onPress={() => openPane($)}
        />
      </Box>
    )
  })
}
