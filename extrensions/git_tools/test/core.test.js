// Tests for the parts that do not need VS Code. Run: node --test test/
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const { execFileSync } = require('child_process');

const { Repository } = require('../src/git');
const { layoutGraph } = require('../src/graph');
const { parseConflicts, joinSegments } = require('../src/conflicts');
const { ClaudeCommitAi, GeminiCommitAi, AiError } = require('../src/ai');

function tempRepo() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gt_ext_'));
  const git = (...a) => execFileSync('git', a, { cwd: dir, stdio: 'pipe' }).toString();
  git('init', '-q', '-b', 'main');
  git('config', 'user.name', 'Test');
  git('config', 'user.email', 't@example.com');
  git('config', 'core.autocrlf', 'false');
  const write = (p, c) => {
    fs.mkdirSync(path.dirname(path.join(dir, p)), { recursive: true });
    fs.writeFileSync(path.join(dir, p), c);
  };
  return { dir, git, write, repo: new Repository(dir), cleanup: () => fs.rmSync(dir, { recursive: true, force: true }) };
}

test('status, partial commit and glob characters in names', async () => {
  const r = tempRepo();
  try {
    r.write('a.txt', 'a\n');
    r.write('app/[id].tsx', 'x\n');
    r.write('app/i.tsx', 'i\n');
    let s = await r.repo.status();
    assert.equal(s.head, null);
    assert.equal(s.branch, 'main');
    assert.deepEqual(s.changes.map((c) => c.type), ['untracked', 'untracked', 'untracked']);

    await r.repo.commit({ message: 'first', paths: ['a.txt', 'app/[id].tsx'] });
    s = await r.repo.status();
    assert.deepEqual(s.changes.map((c) => c.path), ['app/i.tsx']);

    r.write('a.txt', 'a2\n');
    await r.repo.commit({ message: 'second', paths: ['app/i.tsx'] });
    s = await r.repo.status();
    assert.deepEqual(s.changes.map((c) => [c.path, c.type]), [['a.txt', 'modified']]);

    const log = await r.repo.log();
    assert.deepEqual(log.map((c) => c.subject), ['second', 'first']);
    assert.ok(log[0].refs.some((x) => x.kind === 'head'));
    assert.ok(log[0].refs.some((x) => x.kind === 'local' && x.name === 'main'));
    const files = await r.repo.changedFiles(log[0].parents[0], log[0].hash);
    assert.deepEqual(files.map((f) => [f.path, f.type]), [['app/i.tsx', 'added']]);
  } finally {
    r.cleanup();
  }
});

test('add to VCS and unversion (drag & drop between groups)', async () => {
  const r = tempRepo();
  try {
    r.write('a.txt', 'a\n');
    await r.repo.commit({ message: 'init', paths: ['a.txt'] });
    r.write('new [1].txt', 'n\n');
    let s = await r.repo.status();
    assert.deepEqual(s.changes.map((c) => [c.path, c.type]), [['new [1].txt', 'untracked']]);
    // Drop on "Changes": git add (literal pathspec).
    await r.repo.git.run(['add', '--', ':(literal)new [1].txt']);
    s = await r.repo.status();
    assert.deepEqual(s.changes.map((c) => [c.path, c.type]), [['new [1].txt', 'added']]);
    // Drop back on "Unversioned Files": git rm --cached keeps the file.
    await r.repo.git.run(['rm', '--cached', '-q', '--', ':(literal)new [1].txt']);
    s = await r.repo.status();
    assert.deepEqual(s.changes.map((c) => [c.path, c.type]), [['new [1].txt', 'untracked']]);
    assert.ok(fs.existsSync(path.join(r.dir, 'new [1].txt')));
  } finally {
    r.cleanup();
  }
});

test('dragging a whole folder: add and unversion many files via stdin', async () => {
  const r = tempRepo();
  try {
    r.write('a.txt', 'a\n');
    await r.repo.commit({ message: 'init', paths: ['a.txt'] });
    const paths = [];
    for (let i = 0; i < 1500; i++) {
      const p = `assets/generated folder/sub ${i % 7}/file [${i}].txt`;
      r.write(p, `${i}\n`);
      paths.push(p);
    }
    const spec = `${paths.map((p) => `:(literal)${p}`).join('\0')}\0`;
    await r.repo.git.run(['add', '--pathspec-from-file=-', '--pathspec-file-nul'], { stdin: spec });
    let s = await r.repo.status();
    assert.equal(s.changes.length, 1500);
    assert.ok(s.changes.every((c) => c.type === 'added'));
    await r.repo.git.run(['rm', '--cached', '-q', '--pathspec-from-file=-', '--pathspec-file-nul'], { stdin: spec });
    s = await r.repo.status();
    assert.equal(s.changes.length, 1500);
    assert.ok(s.changes.every((c) => c.type === 'untracked'));
  } finally {
    r.cleanup();
  }
});

test('commit only selected lines through a temporary index', async () => {
  const { parseDiff, buildContent } = require('../src/lineSelection');
  const r = tempRepo();
  try {
    r.write('f.txt', 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n');
    r.write('other.txt', 'o\n');
    await r.repo.commit({ message: 'init', paths: ['f.txt', 'other.txt'] });
    // Two separate changes; a third file is staged by the user beforehand.
    r.write('f.txt', 'ONE\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\n');
    r.write('other.txt', 'o2\n');
    r.git('add', 'other.txt');
    r.write('new.txt', 'new\n');

    const parsed = parseDiff(await r.repo.fileDiff('f.txt'));
    // Leave out "+eleven": exclude the keys of that line.
    const excluded = new Set();
    parsed.hunks.forEach((hk, i) => hk.lines.forEach((l, j) => { if (l.text === 'eleven') excluded.add(`${i}:${j}`); }));
    const head = (await r.repo.show('HEAD', 'f.txt')).toString('utf8');
    const content = buildContent(head, parsed, excluded);

    await r.repo.commitSelected({ message: 'partial', fullPaths: ['new.txt'], partial: [{ path: 'f.txt', content }] });

    assert.equal(r.git('show', 'HEAD:f.txt'), 'ONE\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n');
    assert.equal(r.git('show', 'HEAD:new.txt'), 'new\n');
    assert.deepEqual(r.git('show', '--name-only', '--format=', 'HEAD').trim().split('\n').sort(), ['f.txt', 'new.txt']);
    // The left-out line stays in the working tree, other.txt stays staged.
    assert.match(fs.readFileSync(path.join(r.dir, 'f.txt'), 'utf8'), /eleven/);
    const s = await r.repo.status();
    assert.deepEqual(s.changes.map((c) => [c.path, c.type]).sort(), [['f.txt', 'modified'], ['other.txt', 'modified']]);
    assert.equal(r.git('diff', '--cached', '--name-only').trim(), 'other.txt');
    assert.equal(r.git('diff', '--', 'f.txt').includes('+eleven'), true);
    assert.equal(fs.readdirSync(path.join(r.dir, '.git')).some((n) => n.startsWith('gittools-index')), false);
  } finally {
    r.cleanup();
  }
});

test('line selection with core.autocrlf=true and CRLF files', async () => {
  const { parseDiff, buildContent } = require('../src/lineSelection');
  const r = tempRepo();
  try {
    r.git('config', 'core.autocrlf', 'true');
    r.write('w.txt', 'a\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng\r\nh\r\n');
    await r.repo.commit({ message: 'init', paths: ['w.txt'] });
    r.write('w.txt', 'A\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng\r\nH\r\n');
    const parsed = parseDiff(await r.repo.fileDiff('w.txt'));
    const excluded = new Set();
    parsed.hunks.forEach((hk, i) => hk.lines.forEach((l, j) => { if (/^[hH]\r?$/.test(l.text)) excluded.add(`${i}:${j}`); }));
    const head = (await r.repo.show('HEAD', 'w.txt')).toString('utf8');
    await r.repo.commitSelected({ message: 'crlf', fullPaths: [], partial: [{ path: 'w.txt', content: buildContent(head, parsed, excluded) }] });
    // Stored normalized (LF) in the repository, only "A" committed.
    assert.equal(r.git('show', 'HEAD:w.txt'), 'A\nb\nc\nd\ne\nf\ng\nh\n');
    const diff = r.git('diff', '--', 'w.txt');
    assert.match(diff, /-h/);
    assert.match(diff, /\+H/);
    assert.doesNotMatch(diff, /[-+]A|[-+]a/);
  } finally {
    r.cleanup();
  }
});

test('rename detection and rollback', async () => {
  const r = tempRepo();
  try {
    r.write('a.txt', 'content of a that is long enough\n');
    r.write('d.txt', 'delete me\n');
    await r.repo.commit({ message: 'init', paths: ['a.txt', 'd.txt'] });
    r.git('mv', 'a.txt', 'b.txt');
    fs.rmSync(path.join(r.dir, 'd.txt'));
    let s = await r.repo.status();
    const ren = s.changes.find((c) => c.type === 'renamed');
    assert.deepEqual([ren.oldPath, ren.path], ['a.txt', 'b.txt']);
    await r.repo.rollback(s.changes, true, false);
    s = await r.repo.status();
    assert.equal(s.changes.length, 0);
  } finally {
    r.cleanup();
  }
});

test('branches, merge conflict, resolution and graph', async () => {
  const r = tempRepo();
  try {
    r.write('f.txt', 'base\n');
    await r.repo.commit({ message: 'base', paths: ['f.txt'] });
    r.git('checkout', '-q', '-b', 'feature');
    r.write('f.txt', 'feature\n');
    await r.repo.commit({ message: 'feature', paths: ['f.txt'] });
    r.git('checkout', '-q', 'main');
    r.write('f.txt', 'main\n');
    await r.repo.commit({ message: 'main', paths: ['f.txt'] });

    const branches = await r.repo.branches();
    assert.deepEqual(branches.map((b) => b.name).sort(), ['feature', 'main']);
    assert.equal(branches.find((b) => b.current).name, 'main');

    await assert.rejects(r.repo.git.run(['merge', '--no-edit', 'feature']));
    let s = await r.repo.status();
    assert.equal(s.state, 'merging');
    assert.equal(s.changes[0].conflictCode, 'UU');

    const segs = parseConflicts(fs.readFileSync(path.join(r.dir, 'f.txt'), 'utf8'));
    const conflict = segs.find((x) => x.kind === 'conflict');
    assert.deepEqual([conflict.ours, conflict.theirs], [['main'], ['feature']]);
    fs.writeFileSync(path.join(r.dir, 'f.txt'), joinSegments(segs, [{ choice: 'theirs' }]));
    await r.repo.markResolved('f.txt');
    await r.repo.continueOperation('merging');
    s = await r.repo.status();
    assert.equal(s.state, 'normal');

    const log = await r.repo.log();
    assert.equal(log[0].parents.length, 2);
    const rows = layoutGraph(log);
    assert.equal(rows[0].segments.filter((x) => x[2] === 1).length, 2);
    assert.ok(rows.some((row) => row.lane === 1));
  } finally {
    r.cleanup();
  }
});

test('stash with untracked files and diffPerFile', async () => {
  const r = tempRepo();
  try {
    r.write('f.txt', '1\n');
    await r.repo.commit({ message: 'base', paths: ['f.txt'] });
    r.write('f.txt', '2\n');
    r.write('new.txt', 'hello\n');
    const diffs = await r.repo.diffPerFile([{ path: 'f.txt', type: 'modified' }, { path: 'new.txt', type: 'untracked' }], 'HEAD');
    assert.match(diffs.get('f.txt'), /-1\n\+2/);
    assert.match(diffs.get('new.txt'), /\+hello/);

    r.git('stash', 'push', '--include-untracked', '-m', 'wip');
    const stashes = await r.repo.stashes();
    assert.equal(stashes.length, 1);
    const files = await r.repo.stashFiles(stashes[0]);
    assert.deepEqual(files.map((f) => f.path).sort(), ['f.txt', 'new.txt']);
    assert.deepEqual(await r.repo.recentSubjects(), ['base']);
  } finally {
    r.cleanup();
  }
});

test('graph: linear history stays in one lane', () => {
  const c = (h, p) => ({ hash: h, parents: p });
  const rows = layoutGraph([c('c', ['b']), c('b', ['a']), c('a', [])]);
  assert.deepEqual(rows.map((r) => r.lane), [0, 0, 0]);
});

// ---------------------------------------------------------------- AI

function fakeServer(handler) {
  return new Promise((resolve) => {
    const requests = [];
    const server = http.createServer((req, res) => {
      let body = '';
      req.on('data', (d) => { body += d; });
      req.on('end', () => {
        requests.push({ headers: req.headers, body: JSON.parse(body) });
        handler(req, res);
      });
    });
    server.listen(0, '127.0.0.1', () => resolve({ server, requests, url: `http://127.0.0.1:${server.address().port}/v1` }));
  });
}

const sse = (events) => (req, res) => {
  res.writeHead(200, { 'content-type': 'text/event-stream' });
  for (const e of events) res.write(`data: ${e}\n\n`);
  res.end();
};

const req = { files: ['modified: a.txt'], diff: '-a\n+b', branch: 'main', recentSubjects: ['Add login'], language: 'English' };

test('Claude: streams text with fallback and effort options', async () => {
  const delta = (t) => JSON.stringify({ type: 'content_block_delta', delta: { type: 'text_delta', text: t } });
  const { server, requests, url } = await fakeServer(sse([
    delta('partial'),
    JSON.stringify({ type: 'content_block_start', content_block: { type: 'fallback' } }),
    delta('Fix greeting'),
    delta('\n\nBody'),
    JSON.stringify({ type: 'message_delta', delta: { stop_reason: 'end_turn' } }),
  ]));
  try {
    const seen = [];
    const ai = new ClaudeCommitAi({ apiKey: 'k1', model: 'claude-opus-5-5', endpoint: url });
    assert.equal(await ai.generate(req, (t) => seen.push(t)), 'Fix greeting\n\nBody');
    assert.ok(seen.includes(''));
    const { headers, body } = requests[0];
    assert.equal(headers['x-api-key'], 'k1');
    assert.equal(headers['anthropic-version'], '2023-06-01');
    assert.equal(headers['anthropic-beta'], 'server-side-fallback-2026-07-01');
    assert.equal(body.fallbacks, 'default');
    assert.deepEqual(body.output_config, { effort: 'low' });
    assert.match(body.messages[0].content, /- Add login/);
  } finally {
    server.close();
  }
});

test('Claude: refusal and HTTP errors', async () => {
  let mode = 'refusal';
  const { server, requests, url } = await fakeServer((rq, res) => {
    if (mode === 'refusal') return sse([JSON.stringify({ type: 'message_delta', delta: { stop_reason: 'refusal' } })])(rq, res);
    res.writeHead(401, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ type: 'error', error: { message: 'invalid x-api-key' } }));
  });
  try {
    const ai = new ClaudeCommitAi({ apiKey: 'k', model: 'claude-haiku-4-5', endpoint: url });
    await assert.rejects(ai.generate(req, () => {}), /declined/);
    assert.equal(requests[0].headers['anthropic-beta'], undefined);
    assert.equal(requests[0].body.output_config, undefined);
    mode = 'error';
    await assert.rejects(ai.generate(req, () => {}), (e) => e instanceof AiError && /Invalid Claude API key/.test(e.message) && /invalid x-api-key/.test(e.message));
  } finally {
    server.close();
  }
});

test('Gemini: OpenAI-compatible stream and quota error', async () => {
  let ok = true;
  const { server, requests, url } = await fakeServer((rq, res) => {
    if (ok) {
      const chunk = (t) => JSON.stringify({ choices: [{ delta: { content: t } }] });
      return sse([chunk('feat: add'), chunk(' login'), '[DONE]'])(rq, res);
    }
    res.writeHead(429, { 'content-type': 'application/json' });
    res.end(JSON.stringify([{ error: { code: 429, message: 'Resource has been exhausted' } }]));
  });
  try {
    const ai = new GeminiCommitAi({ apiKey: 'g1', model: 'gemini-3.8-flash', endpoint: url });
    assert.equal(await ai.generate(req, () => {}), 'feat: add login');
    assert.equal(requests[0].headers.authorization, 'Bearer g1');
    assert.equal(requests[0].body.reasoning_effort, 'low');
    assert.equal(requests[0].body.messages[0].role, 'system');
    ok = false;
    await assert.rejects(ai.generate(req, () => {}), /quota.*exhausted/s);
  } finally {
    server.close();
  }
});

test('AI: cancel aborts the request', async () => {
  const { server, url } = await fakeServer(() => { /* never answers */ });
  try {
    const ai = new GeminiCommitAi({ apiKey: 'g', model: 'm', endpoint: url });
    const p = ai.generate(req, () => {});
    setTimeout(() => ai.cancel(), 100);
    await assert.rejects(p, (e) => e instanceof AiError && e.cancelled);
  } finally {
    server.closeAllConnections();
    server.close();
  }
});
