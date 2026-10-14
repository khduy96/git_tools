// @ts-check
'use strict';

/**
 * Line level selection of changes (Android Studio "partial commit").
 *
 * A file diff (HEAD → working tree) is parsed into hunks. Every changed line
 * ('+' or '-') has a stable key "<hunk>:<line>" within that diff; the
 * selection is stored as the set of *excluded* keys. From the HEAD content
 * and the selection we build the exact content to commit.
 */

/**
 * @typedef {{kind: ' '|'+'|'-', text: string, noEol: boolean}} DiffLine
 * @typedef {{oldStart: number, oldLen: number, newStart: number, newLen: number, header: string, lines: DiffLine[]}} Hunk
 * @typedef {{hunks: Hunk[], binary: boolean, signature: string}} ParsedDiff
 */

const HUNK = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$/;

/**
 * Parses the output of `git diff` for a single file.
 * @param {string} text
 * @returns {ParsedDiff}
 */
function parseDiff(text) {
  /** @type {Hunk[]} */
  const hunks = [];
  let binary = false;
  /** @type {Hunk|null} */
  let cur = null;
  const lines = text.split('\n');
  if (lines.length && lines[lines.length - 1] === '') lines.pop();
  for (const line of lines) {
    const m = HUNK.exec(line);
    if (m) {
      cur = {
        oldStart: Number(m[1]),
        oldLen: m[2] === undefined ? 1 : Number(m[2]),
        newStart: Number(m[3]),
        newLen: m[4] === undefined ? 1 : Number(m[4]),
        header: m[5].trim(),
        lines: [],
      };
      hunks.push(cur);
      continue;
    }
    if (!cur) {
      if (line.startsWith('Binary files ')) binary = true;
      continue;
    }
    const c = line[0];
    if (c === ' ' || c === '+' || c === '-') {
      cur.lines.push({ kind: /** @type {any} */ (c), text: line.slice(1), noEol: false });
    } else if (c === '\\' && cur.lines.length) {
      // "\ No newline at end of file" applies to the previous line.
      cur.lines[cur.lines.length - 1].noEol = true;
    }
  }
  return { hunks, binary, signature: signature(hunks) };
}

/** Cheap content hash used to detect that a diff changed since selection. */
function signature(hunks) {
  let h = 2166136261;
  for (const hk of hunks) {
    const s = `${hk.oldStart},${hk.oldLen},${hk.newStart},${hk.newLen}`;
    for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619);
    for (const l of hk.lines) {
      const t = l.kind + l.text + (l.noEol ? '\\' : '');
      for (let i = 0; i < t.length; i++) h = Math.imul(h ^ t.charCodeAt(i), 16777619);
      h = Math.imul(h ^ 10, 16777619);
    }
  }
  return (h >>> 0).toString(16);
}

const keyOf = (hunk, line) => `${hunk}:${line}`;

/** All selectable keys of a diff. */
function changeKeys(parsed) {
  const keys = [];
  parsed.hunks.forEach((hk, i) => hk.lines.forEach((l, j) => {
    if (l.kind !== ' ') keys.push(keyOf(i, j));
  }));
  return keys;
}

/**
 * Splits text into lines that keep their terminator.
 * @param {string} text
 */
function splitKeepEol(text) {
  return text.match(/[^\n]*\n|[^\n]+$/g) || [];
}

/**
 * Content of the file with only the selected changes applied to `oldText`.
 * Unselected deletions keep the old line, unselected additions are dropped.
 * @param {string} oldText content at HEAD
 * @param {ParsedDiff} parsed diff HEAD → working tree
 * @param {Set<string>} excluded keys of changes left out
 */
function buildContent(oldText, parsed, excluded) {
  const old = splitKeepEol(oldText);
  const out = [];
  let oi = 0; // index into old (0-based)
  parsed.hunks.forEach((hk, i) => {
    // A hunk with oldLen 0 inserts after line oldStart; otherwise it starts at oldStart.
    const start = hk.oldLen === 0 ? hk.oldStart : hk.oldStart - 1;
    while (oi < start && oi < old.length) out.push(old[oi++]);
    hk.lines.forEach((l, j) => {
      const selected = !excluded.has(keyOf(i, j));
      if (l.kind === ' ') {
        out.push(old[oi++]);
      } else if (l.kind === '-') {
        if (selected) oi++;
        else out.push(old[oi++]);
      } else if (selected) {
        out.push(l.noEol ? l.text : `${l.text}\n`);
      }
    });
  });
  while (oi < old.length) out.push(old[oi++]);
  // An unselected "no newline at EOF" addition may leave the last kept line
  // without its terminator; make sure lines stay separated.
  for (let k = 0; k < out.length - 1; k++) {
    if (out[k] !== undefined && !out[k].endsWith('\n')) out[k] += '\n';
  }
  return out.filter((x) => x !== undefined).join('');
}

/**
 * Diff text limited to the selected changes (for display / AI prompts).
 * @param {string} filePath
 * @param {ParsedDiff} parsed
 * @param {Set<string>} excluded
 */
function filteredPatch(filePath, parsed, excluded) {
  const out = [`diff --git a/${filePath} b/${filePath}`, `--- a/${filePath}`, `+++ b/${filePath}`];
  let shift = 0;
  parsed.hunks.forEach((hk, i) => {
    const lines = [];
    let oldLen = 0;
    let newLen = 0;
    let changed = false;
    hk.lines.forEach((l, j) => {
      const selected = !excluded.has(keyOf(i, j));
      if (l.kind === ' ' || (l.kind === '-' && !selected)) {
        lines.push(` ${l.text}`);
        oldLen++;
        newLen++;
      } else if (l.kind === '-') {
        lines.push(`-${l.text}`);
        oldLen++;
        changed = true;
      } else if (selected) {
        lines.push(`+${l.text}`);
        newLen++;
        changed = true;
      }
    });
    if (changed) {
      out.push(`@@ -${hk.oldStart},${oldLen} +${hk.oldStart + shift},${newLen} @@${hk.header ? ` ${hk.header}` : ''}`, ...lines);
    }
    shift += newLen - oldLen;
  });
  return `${out.join('\n')}\n`;
}

/**
 * Describes excluded lines independently of their position, so a selection
 * survives edits elsewhere in the file: "<kind><text>#<occurrence>".
 * @param {ParsedDiff} parsed
 * @param {Set<string>} excluded
 */
function describe(parsed, excluded) {
  const seen = new Map();
  const out = new Set();
  parsed.hunks.forEach((hk, i) => hk.lines.forEach((l, j) => {
    if (l.kind === ' ') return;
    const id = `${l.kind}${l.text}`;
    const n = (seen.get(id) || 0) + 1;
    seen.set(id, n);
    if (excluded.has(keyOf(i, j))) out.add(`${id}#${n}`);
  }));
  return out;
}

/**
 * Maps described exclusions onto the keys of a new diff.
 * @param {ParsedDiff} parsed
 * @param {Set<string>} described
 */
function remap(parsed, described) {
  const seen = new Map();
  const excluded = [];
  parsed.hunks.forEach((hk, i) => hk.lines.forEach((l, j) => {
    if (l.kind === ' ') return;
    const id = `${l.kind}${l.text}`;
    const n = (seen.get(id) || 0) + 1;
    seen.set(id, n);
    if (described.has(`${id}#${n}`)) excluded.push(keyOf(i, j));
  }));
  return excluded;
}

/** Number of selected / total changed lines. */
function stats(parsed, excluded) {
  const keys = changeKeys(parsed);
  return { total: keys.length, selected: keys.filter((k) => !excluded.has(k)).length };
}

module.exports = { parseDiff, buildContent, filteredPatch, changeKeys, splitKeepEol, stats, keyOf, describe, remap };
