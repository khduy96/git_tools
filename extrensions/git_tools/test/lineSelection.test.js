// Tests for line level selection. Run: node --test test/lineSelection.test.js
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { parseDiff, buildContent, changeKeys, filteredPatch, stats, describe, remap } = require('../src/lineSelection');

/** Real `git diff --no-index` between two texts. */
function gitDiff(oldText, newText, context = 3) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gt_ls_'));
  try {
    fs.writeFileSync(path.join(dir, 'a'), oldText);
    fs.writeFileSync(path.join(dir, 'b'), newText);
    try {
      return execFileSync('git', ['-c', 'core.autocrlf=false', 'diff', '--no-index', '--no-color', `-U${context}`, 'a', 'b'], { cwd: dir }).toString();
    } catch (e) {
      return e.stdout.toString(); // exit code 1 when files differ
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

/** Builds content with the changes whose text matches `pick` selected. */
function apply(oldText, newText, pick, context) {
  const parsed = parseDiff(gitDiff(oldText, newText, context));
  const excluded = new Set();
  parsed.hunks.forEach((hk, i) => hk.lines.forEach((l, j) => {
    if (l.kind !== ' ' && !pick(l)) excluded.add(`${i}:${j}`);
  }));
  return { parsed, excluded, content: buildContent(oldText, parsed, excluded) };
}

const OLD = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l'].map((x) => `${x}\n`).join('');

test('all selected reproduces the new file, none selected the old one', () => {
  const NEW = OLD.replace('b\n', 'B\n').replace('k\n', 'k\nk2\n').replace('f\n', '');
  for (const ctx of [0, 3]) {
    assert.equal(apply(OLD, NEW, () => true, ctx).content, NEW);
    assert.equal(apply(OLD, NEW, () => false, ctx).content, OLD);
  }
});

test('selecting single changes', () => {
  const NEW = OLD.replace('b\n', 'B\n').replace('k\n', 'k\nk2\n').replace('f\n', '');
  // Only the addition of k2.
  assert.equal(apply(OLD, NEW, (l) => l.text === 'k2').content, OLD.replace('k\n', 'k\nk2\n'));
  // Only the deletion of f.
  assert.equal(apply(OLD, NEW, (l) => l.kind === '-' && l.text === 'f').content, OLD.replace('f\n', ''));
  // Only "b" removed but "B" not added.
  assert.equal(apply(OLD, NEW, (l) => l.text === 'b').content, OLD.replace('b\n', ''));
});

test('insertion at the top and at the end, no newline at EOF', () => {
  const NEW = `top\n${OLD}end`;
  assert.equal(apply(OLD, NEW, () => true).content, NEW);
  assert.equal(apply(OLD, NEW, (l) => l.text === 'top').content, `top\n${OLD}`);
  assert.equal(apply(OLD, NEW, (l) => l.text === 'end').content, `${OLD}end`);
  // Old file without trailing newline, new line appended after it.
  const OLD2 = 'x\ny';
  const NEW2 = 'x\ny\nz\n';
  assert.equal(apply(OLD2, NEW2, () => true).content, NEW2);
  assert.equal(apply(OLD2, NEW2, () => false).content, OLD2);
});

test('new file from empty and stats / signature', () => {
  const NEW = 'one\ntwo\nthree\n';
  const r = apply('', NEW, (l) => l.text !== 'two');
  assert.equal(r.content, 'one\nthree\n');
  assert.deepEqual(stats(r.parsed, r.excluded), { total: 3, selected: 2 });
  assert.equal(changeKeys(r.parsed).length, 3);
  const again = parseDiff(gitDiff('', NEW));
  assert.equal(again.signature, r.parsed.signature);
  assert.notEqual(parseDiff(gitDiff('', 'one\n')).signature, r.parsed.signature);
});

test('random edits: building with a random selection equals applying that patch with git', () => {
  let seed = 7;
  const rnd = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648);
  for (let round = 0; round < 40; round++) {
    const oldLines = Array.from({ length: 30 }, (_, i) => `line ${i} ${Math.floor(rnd() * 5)}`);
    const newLines = [];
    for (const l of oldLines) {
      const r = rnd();
      if (r < 0.15) continue; // delete
      if (r < 0.3) newLines.push(`${l} changed`);
      else newLines.push(l);
      if (rnd() < 0.1) newLines.push(`inserted ${round}`);
    }
    const oldText = `${oldLines.join('\n')}\n`;
    const newText = `${newLines.join('\n')}\n`;
    const r = apply(oldText, newText, () => rnd() < 0.5);
    // Applying the filtered patch with git must give the same content.
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gt_ls_apply_'));
    try {
      fs.writeFileSync(path.join(dir, 'f'), oldText);
      fs.writeFileSync(path.join(dir, 'p.diff'), filteredPatch('f', r.parsed, r.excluded));
      execFileSync('git', ['-c', 'core.autocrlf=false', 'apply', '--unidiff-zero', 'p.diff'], { cwd: dir });
      assert.equal(fs.readFileSync(path.join(dir, 'f'), 'utf8'), r.content, `round ${round}`);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  }
});

test('selection survives an edit elsewhere in the file', () => {
  const NEW = OLD.replace('b\n', 'B\n').replace('k\n', 'K\n');
  const r = apply(OLD, NEW, (l) => l.text !== 'K'); // leave out the K change (only "+K")
  // The user then edits another part of the file: hunks and keys shift.
  const NEW2 = `inserted at top\n${NEW}`;
  const parsed2 = parseDiff(gitDiff(OLD, NEW2));
  const excluded2 = new Set(remap(parsed2, describe(r.parsed, r.excluded)));
  assert.equal(excluded2.size, 1);
  const content = buildContent(OLD, parsed2, excluded2);
  assert.equal(content, `inserted at top\n${OLD.replace('b\n', 'B\n').replace('k\n', '')}`);
});
