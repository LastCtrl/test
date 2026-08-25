'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { slugify, truncate, capitalize } = require('../src/string-utils');

// ── slugify ────────────────────────────────────────────────

describe('slugify', () => {
  it('converts normal string', () => {
    assert.equal(slugify('Hello World!'), 'hello-world');
  });

  it('handles multiple special characters', () => {
    assert.equal(slugify('foo---bar___baz'), 'foo-bar-baz');
  });

  it('returns empty string for null', () => {
    assert.equal(slugify(null), '');
  });

  it('returns empty string for empty input', () => {
    assert.equal(slugify(''), '');
  });

  it('trims leading/trailing hyphens', () => {
    assert.equal(slugify('  --hello--  '), 'hello');
  });

  it('handles cyrillic', () => {
    assert.equal(slugify('Привет Мир 2026'), 'привет-мир-2026');
  });
});

// ── truncate ───────────────────────────────────────────────

describe('truncate', () => {
  it('returns full string when shorter than maxLen', () => {
    assert.equal(truncate('hi', 10), 'hi');
  });

  it('truncates and appends ellipsis', () => {
    assert.equal(truncate('hello world', 5), 'he...');
  });

  it('returns full string when length equals maxLen exactly', () => {
    assert.equal(truncate('abcde', 5), 'abcde');
  });

  it('returns empty string for null', () => {
    assert.equal(truncate(null, 10), '');
  });

  it('returns empty string for empty input', () => {
    assert.equal(truncate('', 5), '');
  });

  it('returns full string when string is shorter than maxLen', () => {
    assert.equal(truncate('abc', 5), 'abc');
  });

  it('throws TypeError when maxLen is not a number', () => {
    assert.throws(() => truncate('hello', undefined), TypeError);
  });

  it('throws TypeError when maxLen is negative', () => {
    assert.throws(() => truncate('hello', -1), TypeError);
  });
});

// ── capitalize ─────────────────────────────────────────────

describe('capitalize', () => {
  it('capitalizes first letter', () => {
    assert.equal(capitalize('hello'), 'Hello');
  });

  it('handles already capitalized', () => {
    assert.equal(capitalize('Hello'), 'Hello');
  });

  it('returns empty string for null', () => {
    assert.equal(capitalize(null), '');
  });

  it('handles single character', () => {
    assert.equal(capitalize('a'), 'A');
  });

  it('preserves rest of string', () => {
    assert.equal(capitalize('hELLO'), 'HELLO');
  });

  it('returns empty string for empty input', () => {
    assert.equal(capitalize(''), '');
  });
});