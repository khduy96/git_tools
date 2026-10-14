// @ts-check
'use strict';

/**
 * Parsing of files that contain git conflict markers.
 * Segments: {kind: 'text', lines} | {kind: 'conflict', ours, base, theirs}
 */

const START = /^<{7}( |$)/;
const BASE = /^\|{7}( |$)/;
const MID = /^={7}$/;
const END = /^>{7}( |$)/;

function hasConflictMarkers(text) {
  return text.split('\n').some((l) => START.test(l.replace(/\r$/, '')));
}

function parseConflicts(text) {
  const lines = text.replace(/\r\n/g, '\n').split('\n');
  if (lines.length && lines[lines.length - 1] === '') lines.pop();
  const segments = [];
  let plain = [];
  let i = 0;
  while (i < lines.length) {
    if (!START.test(lines[i])) {
      plain.push(lines[i++]);
      continue;
    }
    const ours = [];
    let base = null;
    const theirs = [];
    let section = 0;
    let j = i + 1;
    let complete = false;
    for (; j < lines.length; j++) {
      const l = lines[j];
      if (section === 0 && BASE.test(l)) {
        section = 1;
        base = [];
      } else if (section < 2 && MID.test(l)) {
        section = 2;
      } else if (section === 2 && END.test(l)) {
        complete = true;
        break;
      } else {
        (section === 0 ? ours : section === 1 ? base : theirs).push(l);
      }
    }
    if (!complete) {
      plain.push(lines[i++]);
      continue;
    }
    if (plain.length) {
      segments.push({ kind: 'text', lines: plain });
      plain = [];
    }
    segments.push({ kind: 'conflict', ours, base, theirs });
    i = j + 1;
  }
  if (plain.length) segments.push({ kind: 'text', lines: plain });
  return segments;
}

/**
 * Lines chosen for a conflict.
 * @param {{ours: string[], base: string[]|null, theirs: string[]}} c
 * @param {string} choice ours|theirs|oursTheirs|theirsOurs|base|custom
 * @param {string[]} [custom]
 */
function resolveConflict(c, choice, custom) {
  switch (choice) {
    case 'ours': return c.ours;
    case 'theirs': return c.theirs;
    case 'oursTheirs': return [...c.ours, ...c.theirs];
    case 'theirsOurs': return [...c.theirs, ...c.ours];
    case 'base': return c.base || [];
    case 'custom': return custom || [];
    default: throw new Error('Unresolved conflict');
  }
}

/**
 * @param {any[]} segments
 * @param {{choice: string, custom?: string[]}[]} resolutions one per conflict, in order
 */
function joinSegments(segments, resolutions, eol = '\n') {
  const out = [];
  let k = 0;
  for (const s of segments) {
    if (s.kind === 'text') out.push(...s.lines);
    else {
      const r = resolutions[k++];
      out.push(...resolveConflict(s, r.choice, r.custom));
    }
  }
  return out.length ? out.join(eol) + eol : '';
}

module.exports = { hasConflictMarkers, parseConflicts, resolveConflict, joinSegments };
