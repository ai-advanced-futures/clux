import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { BgSession, BgStatus } from '../types'
import {
  LABEL,
  isFresh,
  newlyBlocked,
  sortSessions,
  toSession,
  worktreePaths,
} from './jobs'

const PANE = 'control-room'
const TITLE = 'Background sessions'
const POLL_MS = 5000
const SOUND = 'sounds/needs-input.wav'
// afplay on macOS; on Linux Claude Code has no player, so try clux's.
const PLAYERS = ['afplay', 'paplay', 'pw-play', 'aplay', 'play']

const sessions = atom({ plugin: 'clux-control-room', key: 'sessions' } as const, [])

const COLOR: Record<BgStatus, string> = {
  'needs-input': 'warning',
  working: 'suggestion',
  done: 'success',
  failed: 'error',
  stopped: 'inactive',
}

// What a poll needs that does not change during a session.
type Scope = { dir: string; roots: string[]; selfId: string }

async function jobsDir($: EngineInterface): Promise<string> {
  const config = await $.env.get('CLAUDE_CONFIG_DIR')
  if (config) return `${config}/jobs`
  return `${await $.env.get('HOME')}/.claude/jobs`
}

// The main working tree and every worktree of the repository, also a
// worktree outside the main tree; the session's folder outside git.
async function repoRoots($: EngineInterface): Promise<string[]> {
  const repo = await $.session.repo().catch(() => null)
  if (!repo) return [await $.session.cwd()]
  const listed = await $.process
    .run(['git', '-C', repo.root, 'worktree', 'list', '--porcelain'])
    .catch(() => undefined)
  const paths = listed?.exitCode === 0 ? worktreePaths(listed.stdout) : []
  return [...new Set([repo.root, ...paths])]
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
    const session = toSession(id, text, scope.roots, scope.selfId)
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
async function poll($: EngineInterface, scope: Scope, isQuiet = false) {
  const list = await readSessions($, scope)
  const before = await read($, sessions)
  if (JSON.stringify(list) !== JSON.stringify(before)) {
    await update($, sessions, () => list)
  }
  const fresh = newlyBlocked(list, before)
  if (isQuiet || fresh.length === 0) return
  for (const session of fresh) {
    $.ui.toast(`${session.name} needs input: ${session.line}`)
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
  if (await $.env.get('TMUX')) {
    const ran = await $.process
      .run(['tmux', 'new-window', '-n', session.name, ...argv])
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

export const register: Register = on => {
  let scope: Scope | undefined

  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'control-room',
      description: 'Show the background sessions of this repository in a pane',
      argumentHint: '[off]',
    })
    const ready: Scope = {
      dir: await jobsDir($),
      roots: await repoRoots($),
      selfId: await $.session.id(),
    }
    scope = ready
    await poll($, ready, true)
    $.clock.every(POLL_MS, () => poll($, ready))

    return next(e)
  })

  on('command.run', { command: 'control-room' }, async ($, e) => {
    const arg = e.args.trim()
    if (arg === 'off' || arg === 'close') {
      await $.ui.close({ id: PANE })
      return { text: 'Background sessions pane closed.' }
    }
    if (scope) await poll($, scope, true)
    await openPane($, true)

    return { text: 'Background sessions pane opened. Press a number to open a session.' }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button, Link } = $.ui.resolve(e)
    const list = await read($, sessions)
    const nameWidth = Math.min(28, Math.max(8, ...list.map(s => s.name.length)))

    return (
      <Box flexDirection="column">
        <Text bold>{TITLE} · {list.length}</Text>
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
                <Link href={pr.href} label={`#${pr.id} `} />
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

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const list = await read($, sessions)
    const { needs, working } = counts(list)
    if (e.props.hasSurvey || needs + working === 0) return next(e)

    const { Box, Text, Button } = $.ui.resolve(e)
    const parts = [
      needs > 0 ? `${needs} needs input` : '',
      working > 0 ? `${working} working` : '',
    ].filter(Boolean)

    return (
      <Box>
        <Text color={needs > 0 ? 'warning' : 'subtle'}>
          {TITLE}: {parts.join(' · ')}{' '}
        </Text>
        <Button key="open-room" label="Show" onPress={() => openPane($, true)} />
      </Box>
    )
  })
}
