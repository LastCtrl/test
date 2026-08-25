'use strict';

/**
 * Converts a string to a URL-friendly slug.
 * Keeps Unicode letters and numbers, lowercases, joins segments with '-'.
 * Surrogate pairs (emojis) may be cut in the middle.
 */
function slugify(str) {
  if (str == null) return '';
  const matches = String(str).toLowerCase().match(/[\p{L}\p{N}]+/gu);
  return matches ? matches.join('-') : '';
}

/**
 * Truncates a string to maxLen characters, appending '...' if truncated.
 * Returns '' for null/undefined input.
 * Throws TypeError if maxLen is not a number or < 0.
 * The ellipsis '...' counts toward the maxLen budget.
 * For maxLen <= 3 returns '...'.slice(0, maxLen) (ellipsis may be truncated).
 * Surrogate pairs (emojis) may be cut in the middle.
 */
function truncate(str, maxLen) {
  if (str == null) return '';
  if (typeof maxLen !== 'number' || maxLen < 0) {
    throw new TypeError('maxLen must be a non-negative number');
  }
  const s = String(str);
  if (s.length <= maxLen) return s;
  if (maxLen <= 3) return '...'.slice(0, maxLen);
  // Ellipsis counts toward the budget: take (maxLen - 3) chars + '...'
  return s.slice(0, maxLen - 3) + '...';
}

/**
 * Capitalizes the first character of a string.
 * Returns '' for null/undefined input.
 */
function capitalize(str) {
  if (str == null) return '';
  const s = String(str);
  if (s.length === 0) return '';
  return s[0].toUpperCase() + s.slice(1);
}

module.exports = { slugify, truncate, capitalize };
