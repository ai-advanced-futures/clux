import { describe, expect, test } from 'claude-code/testing'

import { displayText, toRows } from '../hooks/notifications/lines'

const WINDOW = 'main:editor Task done|||$sess1:@win3'
const LEGACY = 'main:editor Task done|ID:$sess1:@win3'
const AGENT = '⚡ agents / pr-flow|||agent:abc-123@@$s9:@w9:%pane3@@/code/clux'
const OLD_AGENT = '⚡ needs input|||agent:s-abc-123'
const BARE = 'main:editor Task done'

describe('displayText', () => {
  test('cuts the ||| marker', () => {
    expect(displayText(WINDOW)).toBe('main:editor Task done')
  })

  test('cuts the legacy |ID: marker', () => {
    expect(displayText(LEGACY)).toBe('main:editor Task done')
  })

  test('cuts the marker of an agent line, new shape and legacy shape', () => {
    expect(displayText(AGENT)).toBe('⚡ agents / pr-flow')
    expect(displayText(OLD_AGENT)).toBe('⚡ needs input')
  })

  test('leaves a line with no marker as it is', () => {
    expect(displayText(BARE)).toBe('main:editor Task done')
  })
})

describe('toRows', () => {
  test('one row for each line, in file order, the whole line kept', () => {
    expect(toRows(`${WINDOW}\n${AGENT}\n`)).toEqual([
      { line: WINDOW, text: 'main:editor Task done', kind: 'window' },
      { line: AGENT, text: '⚡ agents / pr-flow', kind: 'agent' },
    ])
  })

  test('an empty file is no rows', () => {
    expect(toRows('')).toEqual([])
  })

  test('a blank line is no row', () => {
    expect(toRows(`\n${WINDOW}\n\n`)).toEqual([
      { line: WINDOW, text: 'main:editor Task done', kind: 'window' },
    ])
  })

  test('a legacy agent line is an agent row, and a bare line a window row', () => {
    expect(toRows(`${OLD_AGENT}\n${BARE}\n`).map(row => row.kind)).toEqual(['agent', 'window'])
  })
})
