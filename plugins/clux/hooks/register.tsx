// The one hooks module of clux.
//
// `hooks.json` takes a single `modules` entry for each plugin — `claude
// plugin validate` says so plainly: "hooks.json `modules` names one hooks
// module per plugin; a second entry is refused" — so this file composes the
// panes instead. Each pane keeps its own folder and its own `register`.
//
// The order is load-bearing. Two `ui.render` hooks on `SessionMode` chain,
// and the one registered FIRST is the outermost: it draws `next(e)` before
// its own label. Notifications first therefore leaves the sessions label on
// the left of the footer and puts the notifications label on the right.

import type { Register } from 'claude-code'

import { register as notifications } from './notifications/register'
import { register as sessions } from './sessions/register'

export const register: Register = (on, options) => {
  notifications(on, options)
  sessions(on, options)
}
