import { describe, expect, test } from 'claude-code/testing'

import { editValue, parseList, rowText, splitRule, validCount } from '../hooks/notifications/filters'

describe('parseList', () => {
  test('one row for each line, in file order', () => {
    expect(parseList('3\tallow\t^feat-\n4\tdeny\twip\n')).toEqual([
      { n: 3, kind: 'allow', text: '^feat-' },
      { n: 4, kind: 'deny', text: 'wip' },
    ])
  })

  test('an invalid row keeps the raw line, tabs and all', () => {
    expect(parseList('5\tinvalid\tblock\tfoo\n')).toEqual([
      { n: 5, kind: 'invalid', text: 'block\tfoo' },
    ])
  })

  test('empty output is no rows, and a line of another shape is skipped', () => {
    expect(parseList('')).toEqual([])
    expect(parseList('x\tallow\ta\n0\tdeny\tb\n2\tmaybe\tc\n7\tdeny\n')).toEqual([])
  })
})

describe('validCount', () => {
  test('counts the rows that are not invalid', () => {
    expect(validCount(parseList('1\tallow\ta\n2\tinvalid\tdeny (\n3\tdeny\tb\n'))).toBe(2)
  })
})

describe('rowText and editValue', () => {
  test('a rule reads as the kind, then the regex in one column', () => {
    expect(rowText({ n: 1, kind: 'allow', text: '^feat-' })).toBe('allow  ^feat-')
    expect(rowText({ n: 2, kind: 'deny', text: 'wip' })).toBe('deny   wip')
  })

  test('an invalid row reads as the raw line', () => {
    expect(rowText({ n: 3, kind: 'invalid', text: 'block foo' })).toBe('block foo')
  })

  test('the box opens with "<kind> <regex>", or the raw line of an invalid row', () => {
    expect(editValue({ n: 1, kind: 'deny', text: 'wip' })).toBe('deny wip')
    expect(editValue({ n: 3, kind: 'invalid', text: 'deny (' })).toBe('deny (')
  })
})

describe('splitRule', () => {
  test('the first word is the kind, the rest is the regex', () => {
    expect(splitRule('deny wip')).toEqual({ kind: 'deny', regex: 'wip' })
    expect(splitRule('  allow   ^feat- x  ')).toEqual({ kind: 'allow', regex: '^feat- x' })
  })

  test('a kind with no regex gives an empty regex', () => {
    expect(splitRule('deny ')).toEqual({ kind: 'deny', regex: '' })
  })

  test('a first word that is not allow or deny is no rule', () => {
    expect(splitRule('block wip')).toBeNull()
    expect(splitRule('')).toBeNull()
    expect(splitRule('Deny wip')).toBeNull()
  })
})
