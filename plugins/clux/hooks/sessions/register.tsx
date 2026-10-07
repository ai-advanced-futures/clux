import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, Timer } from 'claude-code'

import type { BgSession, BgStatus } from '../../types'
import {
  LABEL,
  isFresh,
  newlyBlocked,
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
const SOUND = 'sounds/needs-input.wav'
// afplay on macOS; on Linux Claude Code has no player, so try clux's.
const PLAYERS = ['afplay', 'paplay', 'pw-play', 'aplay', 'play']

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

async function readSessions($: EngineInterface, scope: Scope) {
  const entries = await $.fs.list(scope.dir).catch(() => [])
  const texts = await Promise.all(
    entries
      .filter(entry => entry.kind === 'dir')
      .map(async entry => ({
        id: entry.name,
        text: await $.fs.read(`${scope.dir}/${entry.name}/state.json`).catch(() => ''),
      })),
  )
  const now = await $.clock.now()
  const found = texts.flatMap(({ id, text }) => {
    if (typeof text !== 'string' || text === '') return []
    const session = toSession(id, text, scope.roots, scope.selfId, now)
    return session && isFresh(session, now) ? [session] : []
  })

  return sortSessions(found)
}

let player: string | undefined

async function playAlert($: EngineInterface) {
  const file = `${$.plugin.root}/${SOUND}`
  for (const name of player ? [player] : PLAYERS) {
    const ran = await $.process.run([name, file], { timeoutMs: 5000 }).catch(() => undefined)
    if (ran?.exitCode === 0) {
      player = name
      return
    }
  }
}

// `isQuiet` takes a baseline: no sound for questions asked before the start.
// One sound for each poll, however many questions it finds.
async function poll($: EngineInterface, scope: Scope, isQuiet: boolean) {
  const list = await readSessions($, scope)
  const before = await read($, sessions)
  if (JSON.stringify(list) !== JSON.stringify(before)) {
    await update($, sessions, () => list)
  }
  const fresh = newlyBlocked(list, before)
  if (isQuiet || fresh.length === 0) return
  for (const session of fresh) {
    $.ui.toast(session.line ? `${session.name} needs input: ${session.line}` : `${session.name} needs input`)
  }
  void playAlert($)
}

// Asked (a command, a press) it seats at any width; `focus` hands it the keys.
function openPane($: EngineInterface, focus = false) {
  return $.ui.open({ id: PANE, title: TITLE, ...(focus ? { focus: true } : {}) })
}

// Selecting a session opens it: a new tmux window that attaches to it, or
// the attach command on the clipboard outside tmux.
async function attach($: EngineInterface, session: BgSession) {
  const argv = ['claude', 'attach', session.id]
  const pane = await $.env.get('TMUX_PANE')
  if (pane && (await $.env.get('TMUX'))) {
    // The new window goes in the tmux session of this pane, not in the
    // session that tmux used last.
    const own = await $.process
      .run(['tmux', 'display-message', '-p', '-t', pane, '#{session_id}'])
      .catch(() => undefined)
    const target = own?.exitCode === 0 ? ['-t', `${own.stdout.trim()}:`] : []
    const ran = await $.process
      .run(['tmux', 'new-window', ...target, '-n', session.name, ...argv])
      .catch(() => undefined)
    if (ran?.exitCode === 0) return
  }
  const command = argv.join(' ')
  await $.ui.copy({ text: command }).catch(() => undefined)
  $.ui.toast(`Copied: ${command}`)
}

function counts(list: readonly BgSession[]) {
  const of = (status: BgStatus) => list.filter(s => s.status === status).length
  return { needs: of('needs-input'), working: of('working') }
}

// The poll loop of this session: set at the start, read by each tick.
const loop: { scope?: Scope; timer?: Timer; isPolling: boolean; polls: number } = {
  isPolling: false,
  polls: 0,
}

// One poll at a time, so a slow poll and the next tick never both alert.
async function tick($: EngineInterface, isQuiet = false) {
  const scope = loop.scope
  if (!scope || loop.isPolling) return
  loop.isPolling = true
  try {
    loop.polls += 1
    if (loop.polls % ROOTS_EVERY === 0) scope.roots = await repoRoots($)
    await poll($, scope, isQuiet)
  } catch (error) {
    $.ui.log(`clux sessions: poll failed: ${String(error)}`, { to: 'debug' })
  } finally {
    loop.isPolling = false
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    try {
      loop.scope = {
        dir: await jobsDir($),
        roots: await repoRoots($),
        selfId: await $.session.id(),
      }
      // Only the first poll after the start is quiet.
      await tick($, true)
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
    await openPane($, true)

    return { text: 'Background sessions pane opened. Press a number to open a session.' }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button, Link } = $.ui.resolve(e)
    const list = await read($, sessions)
    const nameWidth = Math.min(28, Math.max(8, ...list.map(s => s.name.length)))

    return (
      <Box flexDirection="column">
        <Box>
          <Text bold>{TITLE} · {list.length} </Text>
          {/* Over the band's Show: the chord closes an open pane. */}
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
                key={`open-${s.id}`}
                plain
                hotkey={i < 9 ? String(i + 1) : undefined}
                label={s.name.slice(0, nameWidth).padEnd(nameWidth)}
                onPress={() => attach($, s)}
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

  // The band shows also when nothing is live, so the chord always has its
  // Show button to press.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const list = await read($, sessions)
    const { needs, working } = counts(list)

    const { Box, Text, Button } = $.ui.resolve(e)
    const parts = [
      needs > 0 ? `${needs} needs input` : '',
      working > 0 ? `${working} working` : '',
    ].filter(Boolean)
    if (parts.length === 0) parts.push('none live')

    return (
      <Box>
        <Text color={needs > 0 ? 'warning' : 'subtle'}>
          {TITLE}: {parts.join(' · ')}{' '}
        </Text>
        <Button
          key="open-sessions"
          label="Show"
          action={TOGGLE_ACTION}
          onPress={() => openPane($, true)}
        />
      </Box>
    )
  })
}
