// @ts-check
'use strict';

const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const FS = '\x1f';
const RS = '\x1e';

class GitError extends Error {
  /**
   * @param {string[]} args
   * @param {number} code
   * @param {string} stderr
   * @param {string} stdout
   */
  constructor(args, code, stderr, stdout) {
    super((stderr || stdout).trim() || `git ${args.join(' ')} failed with exit code ${code}`);
    this.args = args;
    this.code = code;
    this.stderr = stderr;
    this.stdout = stdout;
  }
}

const GLOBAL_ARGS = [
  '-c', 'core.quotepath=false',
  '-c', 'color.ui=false',
  '-c', 'i18n.logOutputEncoding=UTF-8',
  '-c', 'advice.detachedHead=false',
];

const ENV = {
  GIT_TERMINAL_PROMPT: '0',
  LC_ALL: 'C.UTF-8',
  LANG: 'en_US.UTF-8',
  GIT_EDITOR: 'true',
  GIT_SEQUENCE_EDITOR: 'true',
  GIT_MERGE_AUTOEDIT: 'no',
};

/** Marks a path as a literal pathspec (glob characters are not expanded). */
const lit = (p) => `:(literal)${p}`;

/**
 * Low level git runner.
 */
class GitRunner {
  /**
   * @param {string} cwd
   * @param {{gitPath?: string, log?: (line: string, kind: 'command'|'output'|'error'|'info') => void}} [opts]
   */
  constructor(cwd, opts = {}) {
    this.cwd = cwd;
    this.gitPath = opts.gitPath || 'git';
    this.log = opts.log || (() => {});
  }

  /**
   * @param {string[]} args
   * @param {{log?: boolean, stdin?: string, allowFailure?: boolean, binary?: boolean, env?: Record<string,string>}} [o]
   * @returns {Promise<{code: number, stdout: string, stderr: string, bytes: Buffer}>}
   */
  raw(args, o = {}) {
    if (o.log) this.log(`git ${args.map((a) => (a === '' || /\s/.test(a) ? `"${a}"` : a)).join(' ')}`, 'command');
    return new Promise((resolve, reject) => {
      const child = spawn(this.gitPath, [...GLOBAL_ARGS, ...args], {
        cwd: this.cwd,
        env: { ...process.env, ...ENV, ...(o.env || {}) },
        windowsHide: true,
      });
      /** @type {Buffer[]} */
      const out = [];
      let err = '';
      child.stdout.on('data', (d) => out.push(d));
      child.stderr.on('data', (d) => {
        const s = d.toString('utf8');
        err += s;
        if (o.log) {
          for (const line of s.split(/\r?\n|\r/)) if (line.trim()) this.log(line, 'output');
        }
      });
      child.on('error', reject);
      child.on('close', (code) => {
        const bytes = Buffer.concat(out);
        const stdout = bytes.toString('utf8');
        if (o.log) {
          const lines = stdout.trim() ? stdout.trim().split(/\r?\n/) : [];
          for (const line of lines.slice(0, 200)) this.log(line, 'output');
          if (lines.length > 200) this.log(`… ${lines.length - 200} more lines`, 'output');
          if (code !== 0) this.log(`exit code ${code}`, 'error');
        }
        resolve({ code: code ?? -1, stdout, stderr: err, bytes });
      });
      if (o.stdin !== undefined) child.stdin.end(o.stdin);
      else child.stdin.end();
    });
  }

  /**
   * Runs git and returns stdout; throws GitError on failure.
   * @param {string[]} args
   * @param {{log?: boolean, stdin?: string, allowFailure?: boolean, env?: Record<string,string>}} [o]
   */
  async run(args, o = {}) {
    const r = await this.raw(args, o);
    if (r.code !== 0 && !o.allowFailure) throw new GitError(args, r.code, r.stderr, r.stdout);
    return r.stdout;
  }
}

/**
 * @typedef {'modified'|'added'|'deleted'|'renamed'|'copied'|'typeChanged'|'untracked'|'conflicted'} ChangeType
 * @typedef {{path: string, oldPath?: string, type: ChangeType, conflictCode?: string}} FileChange
 * @typedef {'normal'|'merging'|'rebasing'|'cherryPicking'|'reverting'} RepoState
 * @typedef {{branch: string|null, head: string|null, upstream: string|null, ahead: number, behind: number, changes: FileChange[], state: RepoState}} Status
 * @typedef {{name: string, kind: 'head'|'local'|'remote'|'tag'}} RefLabel
 * @typedef {{hash: string, parents: string[], author: string, email: string, time: number, committer: string, commitTime: number, refs: RefLabel[], subject: string}} Commit
 * @typedef {{name: string, remote: boolean, hash: string, current: boolean, upstream: string|null, ahead: number, behind: number, gone: boolean}} Branch
 */

const LETTER = {
  M: 'modified', A: 'added', D: 'deleted', R: 'renamed', C: 'copied', T: 'typeChanged', U: 'conflicted',
};

const LOG_FORMAT = `%H${FS}%P${FS}%an${FS}%ae${FS}%at${FS}%cn${FS}%ct${FS}%D${FS}%s${RS}`;

/** Splits into at most n fields, the last keeps the remainder. */
function splitN(s, sep, n) {
  const out = [];
  let start = 0;
  while (out.length < n - 1) {
    const i = s.indexOf(sep, start);
    if (i < 0) break;
    out.push(s.slice(start, i));
    start = i + sep.length;
  }
  out.push(s.slice(start));
  return out;
}

const byPath = (a, b) => a.path.toLowerCase().localeCompare(b.path.toLowerCase());

/** Parses `git status --porcelain=v2 -z --branch`. */
function parseStatus(out) {
  /** @type {Status} */
  const s = { branch: null, head: null, upstream: null, ahead: 0, behind: 0, changes: [], state: 'normal' };
  const parts = out.split('\0');
  for (let i = 0; i < parts.length; i++) {
    const e = parts[i];
    if (!e) continue;
    if (e.startsWith('# ')) {
      const f = e.slice(2).split(' ');
      if (f[0] === 'branch.oid') s.head = f[1] === '(initial)' ? null : f[1];
      else if (f[0] === 'branch.head') s.branch = f[1] === '(detached)' ? null : f.slice(1).join(' ');
      else if (f[0] === 'branch.upstream') s.upstream = f.slice(1).join(' ');
      else if (f[0] === 'branch.ab') {
        s.ahead = parseInt(f[1].slice(1), 10) || 0;
        s.behind = parseInt(f[2].slice(1), 10) || 0;
      }
      continue;
    }
    if (e[0] === '1') {
      const f = splitN(e, ' ', 9);
      const [x, y] = f[1];
      /** @type {ChangeType} */
      let type = 'modified';
      if (x === 'A') type = y === 'D' ? 'deleted' : 'added';
      else if (x === 'D' || y === 'D') type = 'deleted';
      else if (x === 'T' || y === 'T') type = 'typeChanged';
      s.changes.push({ path: f[8], type });
    } else if (e[0] === '2') {
      const f = splitN(e, ' ', 10);
      const orig = parts[++i];
      s.changes.push({ path: f[9], oldPath: orig, type: f[8].startsWith('C') ? 'copied' : 'renamed' });
    } else if (e[0] === 'u') {
      const f = splitN(e, ' ', 11);
      s.changes.push({ path: f[10], type: 'conflicted', conflictCode: f[1] });
    } else if (e[0] === '?') {
      s.changes.push({ path: e.slice(2), type: 'untracked' });
    }
  }
  s.changes.sort(byPath);
  return s;
}

/** Parses `%D` decorations produced with --decorate=full. */
function parseRefs(d) {
  /** @type {RefLabel[]} */
  const refs = [];
  if (!d.trim()) return refs;
  for (let r of d.split(', ')) {
    r = r.trim();
    if (r.startsWith('HEAD -> ')) {
      refs.push({ name: 'HEAD', kind: 'head' });
      r = r.slice(8);
    }
    if (r === 'HEAD') refs.push({ name: 'HEAD', kind: 'head' });
    else if (r.startsWith('tag: ')) refs.push({ name: r.slice(5).replace(/^refs\/tags\//, ''), kind: 'tag' });
    else if (r.startsWith('refs/heads/')) refs.push({ name: r.slice(11), kind: 'local' });
    else if (r.startsWith('refs/remotes/')) {
      if (!r.endsWith('/HEAD')) refs.push({ name: r.slice(13), kind: 'remote' });
    } else if (!r.startsWith('refs/stash')) refs.push({ name: r, kind: 'local' });
  }
  return refs;
}

/** @returns {Commit[]} */
function parseCommits(out) {
  const commits = [];
  for (let rec of out.split(RS)) {
    rec = rec.replace(/^\s+/, '');
    if (!rec) continue;
    const f = rec.split(FS);
    if (f.length < 9) continue;
    commits.push({
      hash: f[0],
      parents: f[1] ? f[1].split(' ') : [],
      author: f[2],
      email: f[3],
      time: parseInt(f[4], 10) * 1000,
      committer: f[5],
      commitTime: parseInt(f[6], 10) * 1000,
      refs: parseRefs(f[7]),
      subject: f.slice(8).join(FS),
    });
  }
  return commits;
}

/** Parses `--name-status -z` output. */
function parseNameStatus(out) {
  const parts = out.split('\0');
  /** @type {FileChange[]} */
  const files = [];
  for (let i = 0; i < parts.length; i++) {
    const s = parts[i];
    if (!s) continue;
    /** @type {ChangeType} */
    const type = LETTER[s[0]] || 'modified';
    if (type === 'renamed' || type === 'copied') {
      const oldPath = parts[++i];
      files.push({ path: parts[++i], oldPath, type });
    } else {
      files.push({ path: parts[++i], type });
    }
  }
  return files.filter((f) => f.path).sort(byPath);
}

/**
 * High level repository operations.
 */
class Repository {
  /**
   * @param {string} root
   * @param {ConstructorParameters<typeof GitRunner>[1]} [opts]
   */
  constructor(root, opts) {
    this.root = root;
    this.git = new GitRunner(root, opts);
    /** @type {string|undefined} */
    this._gitDir = undefined;
  }

  get name() {
    return path.basename(this.root);
  }

  /** @returns {Promise<string|null>} top level of the repository containing dir */
  static async findRoot(dir, gitPath) {
    try {
      const r = await new GitRunner(dir, { gitPath }).raw(['rev-parse', '--show-toplevel']);
      return r.code === 0 && r.stdout.trim() ? path.normalize(r.stdout.trim()) : null;
    } catch {
      return null;
    }
  }

  async gitDir() {
    if (!this._gitDir) {
      this._gitDir = path.normalize((await this.git.run(['rev-parse', '--absolute-git-dir'])).trim());
    }
    return this._gitDir;
  }

  // ---------------------------------------------------------------- status

  /** @returns {Promise<Status>} */
  async status() {
    const out = await this.git.run([
      '--no-optional-locks', 'status', '--porcelain=v2', '-z', '--branch', '--untracked-files=all',
    ]);
    const s = parseStatus(out);
    s.state = await this.repoState();
    return s;
  }

  /** @returns {Promise<RepoState>} */
  async repoState() {
    const dir = await this.gitDir();
    const exists = (n) => fs.existsSync(path.join(dir, n));
    if (exists('rebase-merge') || exists('rebase-apply')) return 'rebasing';
    if (exists('MERGE_HEAD')) return 'merging';
    if (exists('CHERRY_PICK_HEAD')) return 'cherryPicking';
    if (exists('REVERT_HEAD')) return 'reverting';
    return 'normal';
  }

  async pendingMergeMessage() {
    const f = path.join(await this.gitDir(), 'MERGE_MSG');
    if (!fs.existsSync(f)) return null;
    const text = fs.readFileSync(f, 'utf8').split('\n').filter((l) => !l.startsWith('#')).join('\n').trim();
    return text || null;
  }

  // ---------------------------------------------------------------- log

  /**
   * @param {{revisions?: string[], path?: string, limit?: number}} [o]
   * @returns {Promise<Commit[]>}
   */
  async log(o = {}) {
    const args = ['log', '--date-order', '--decorate=full', '-n', String(o.limit || 2000), `--format=${LOG_FORMAT}`];
    if (o.revisions && o.revisions.length) args.push(...o.revisions);
    else args.push(o.path ? 'HEAD' : '--all');
    if (o.path) args.push('--follow', '--', lit(o.path));
    const r = await this.git.raw(args);
    if (r.code !== 0) {
      if (/does not have any commits|unknown revision|bad default revision/.test(r.stderr)) return [];
      throw new GitError(args, r.code, r.stderr, r.stdout);
    }
    return parseCommits(r.stdout);
  }

  /** Commits reachable from `to` but not from `from`. */
  async commitsBetween(from, to) {
    const r = await this.git.raw(['log', '--date-order', '--decorate=full', `--format=${LOG_FORMAT}`, `${from}..${to}`]);
    return r.code === 0 ? parseCommits(r.stdout) : [];
  }

  /** Commits of `ref` not on `remoteRef` (or on no branch of `remote`). */
  async outgoing(ref, remote, remoteRef) {
    const args = ['log', '--date-order', '--decorate=full', `--format=${LOG_FORMAT}`, ref];
    if (remoteRef) args.push(`^${remoteRef}`);
    else args.push('--not', `--remotes=${remote}`);
    const r = await this.git.raw(args);
    return r.code === 0 ? parseCommits(r.stdout) : [];
  }

  async commitBody(hash) {
    return (await this.git.run(['show', '-s', '--format=%B', hash])).trim();
  }

  /** Files changed between two revisions; null `from` = empty tree. */
  async changedFiles(from, to) {
    const args = ['diff-tree', '-r', '-z', '-M', '--name-status', '--no-commit-id'];
    if (from) args.push(from);
    else args.push('--root');
    args.push(to);
    return parseNameStatus(await this.git.run(args));
  }

  async branchesContaining(hash) {
    const out = await this.git.run(['branch', '-a', '--format=%(refname:short)', '--contains', hash], { allowFailure: true });
    return out.split('\n').map((l) => l.trim()).filter((l) => l && !l.endsWith('/HEAD'));
  }

  async refExists(ref) {
    return (await this.git.raw(['rev-parse', '--verify', '--quiet', ref])).code === 0;
  }

  // ---------------------------------------------------------------- refs

  /** @returns {Promise<Branch[]>} */
  async branches() {
    const out = await this.git.run([
      'for-each-ref',
      `--format=%(refname)${FS}%(objectname)${FS}%(upstream:short)${FS}%(upstream:track)${FS}%(HEAD)`,
      'refs/heads', 'refs/remotes',
    ]);
    const count = (t, w) => {
      const m = new RegExp(`${w} (\\d+)`).exec(t);
      return m ? parseInt(m[1], 10) : 0;
    };
    return out.split('\n').filter((l) => l.trim()).map((l) => l.split(FS))
      .filter((f) => !(f[0].startsWith('refs/remotes/') && f[0].endsWith('/HEAD')))
      .map((f) => {
        const remote = f[0].startsWith('refs/remotes/');
        return {
          name: f[0].slice(remote ? 13 : 11),
          remote,
          hash: f[1],
          upstream: f[2] || null,
          ahead: count(f[3], 'ahead'),
          behind: count(f[3], 'behind'),
          gone: f[3].includes('gone'),
          current: f[4] === '*',
        };
      });
  }

  async tags() {
    const out = await this.git.run([
      'for-each-ref', '--sort=-creatordate', `--format=%(refname:short)${FS}%(objectname)${FS}%(*objectname)`, 'refs/tags',
    ]);
    return out.split('\n').filter((l) => l.trim()).map((l) => {
      const f = l.split(FS);
      return { name: f[0], hash: f[2] || f[1] };
    });
  }

  async remotes() {
    const out = await this.git.run(['remote', '-v']);
    const seen = new Map();
    for (const line of out.split('\n')) {
      const m = /^(\S+)\s+(\S+)\s+\((fetch|push)\)/.exec(line);
      if (m && !seen.has(m[1])) seen.set(m[1], m[2]);
    }
    return [...seen].map(([name, url]) => ({ name, url }));
  }

  async stashes() {
    const out = await this.git.run(['stash', 'list', `--format=%gd${FS}%H${FS}%ct${FS}%gs`], { allowFailure: true });
    return out.split('\n').filter((l) => l.trim()).map((l, i) => {
      const f = l.split(FS);
      const m = /\{(\d+)\}/.exec(f[0]);
      return { index: m ? parseInt(m[1], 10) : i, ref: f[0], hash: f[1], time: parseInt(f[2], 10) * 1000, message: f.slice(3).join(FS) };
    });
  }

  async stashFiles(stash) {
    const files = await this.changedFiles(`${stash.hash}^1`, stash.hash);
    const u = await this.git.raw(['diff-tree', '-r', '-z', '--name-status', '--no-commit-id', '--root', `${stash.hash}^3`]);
    if (u.code === 0) files.push(...parseNameStatus(u.stdout).map((f) => ({ path: f.path, type: /** @type {ChangeType} */ ('untracked') })));
    return files;
  }

  // ---------------------------------------------------------------- content

  /**
   * Content of `filePath` at `rev` ('' = index, 'HEAD', hash...). Null if missing.
   * @returns {Promise<Buffer|null>}
   */
  async show(rev, filePath) {
    const r = await this.git.raw(['show', `${rev}:${filePath}`]);
    return r.code === 0 ? r.bytes : null;
  }

  /** Per file unified diff against `base`; untracked / new files as additions. */
  async diffPerFile(changes, base) {
    /** @type {Map<string,string>} */
    const result = new Map();
    const tracked = base ? changes.filter((c) => c.type !== 'untracked') : [];
    if (tracked.length) {
      const paths = tracked.flatMap((c) => (c.oldPath ? [c.path, c.oldPath] : [c.path])).map(lit);
      const out = await this.git.run(['diff', '--no-color', '--no-ext-diff', '-M', base, '--', ...paths]);
      for (const chunk of out.split(/^(?=diff --git )/m)) {
        if (!chunk.trim()) continue;
        const m = /^diff --git a\/.* b\/(.*)$/m.exec(chunk);
        result.set(m ? m[1] : chunk.split('\n')[0], chunk);
      }
    }
    for (const c of changes) {
      if (base && c.type !== 'untracked') continue;
      const full = path.join(this.root, c.path);
      if (!fs.existsSync(full)) continue;
      const bytes = fs.readFileSync(full);
      if (bytes.subarray(0, 8000).includes(0)) {
        result.set(c.path, `new binary file: ${c.path} (${bytes.length} bytes)\n`);
        continue;
      }
      const text = bytes.toString('utf8');
      result.set(c.path, `new file: ${c.path}\n${text.split('\n').map((l) => `+${l}`).join('\n')}\n`);
    }
    return result;
  }

  async recentSubjects(count = 15) {
    const r = await this.git.raw(['log', `-${count}`, '--format=%s']);
    return r.code === 0 ? r.stdout.split('\n').filter((l) => l.trim()) : [];
  }

  async lastCommitMessage() {
    return (await this.git.run(['log', '-1', '--format=%B'])).trim();
  }

  // ---------------------------------------------------------------- commit

  /**
   * Commits only `paths` (Android Studio style, no staging area exposed).
   * @param {{message: string, paths: string[], amend?: boolean, signOff?: boolean, partial?: boolean}} o
   */
  async commit(o) {
    const os = require('os');
    const msgFile = path.join(os.tmpdir(), `git_tools_msg_${Date.now()}_${process.pid}.txt`);
    fs.writeFileSync(msgFile, o.message, 'utf8');
    const spec = o.paths.map(lit).join('\0') + '\0';
    const partial = o.partial !== false;
    try {
      if (o.paths.length) {
        await this.git.run(['add', '-A', '--pathspec-from-file=-', '--pathspec-file-nul'], { stdin: spec, log: true });
      }
      const args = ['commit', '-F', msgFile];
      if (o.amend) args.push('--amend');
      if (o.signOff) args.push('--signoff');
      if (partial && (o.paths.length || o.amend)) args.push('--only');
      if (partial && o.paths.length) args.push('--pathspec-from-file=-', '--pathspec-file-nul');
      await this.git.run(args, { stdin: partial && o.paths.length ? spec : undefined, log: true });
    } finally {
      try { fs.unlinkSync(msgFile); } catch { /* ignore */ }
    }
  }

  /** Diff of one tracked file: HEAD → working tree. */
  async fileDiff(filePath) {
    return this.git.run(['diff', '--no-color', '--no-ext-diff', 'HEAD', '--', lit(filePath)]);
  }

  /**
   * Commits through a temporary index, so only the given content is
   * committed and the user's real index is left alone (hooks still run).
   *   fullPaths: committed as they are in the working tree
   *   partial:   [{path, content}] committed with exactly this content
   * @param {{message: string, fullPaths: string[], partial: {path: string, content: string}[], amend?: boolean, signOff?: boolean}} o
   */
  async commitSelected(o) {
    const os = require('os');
    const dir = await this.gitDir();
    const tmpIndex = path.join(dir, `gittools-index-${process.pid}-${Date.now()}`);
    const msgFile = path.join(os.tmpdir(), `git_tools_msg_${Date.now()}_${process.pid}.txt`);
    fs.writeFileSync(msgFile, o.message, 'utf8');
    const env = { GIT_INDEX_FILE: tmpIndex };
    const hasHead = await this.refExists('HEAD');
    const allPaths = [...o.fullPaths, ...o.partial.map((p) => p.path)];
    try {
      await this.git.run(hasHead ? ['read-tree', 'HEAD'] : ['read-tree', '--empty'], { env, log: true });
      if (o.fullPaths.length) {
        await this.git.run(['add', '-A', '--pathspec-from-file=-', '--pathspec-file-nul'],
          { env, stdin: `${o.fullPaths.map(lit).join('\0')}\0`, log: true });
      }
      for (const p of o.partial) {
        // --path applies the clean filters (e.g. CRLF → LF) like `git add`.
        const sha = (await this.git.run(['hash-object', '-w', '--stdin', `--path=${p.path}`], { stdin: p.content })).trim();
        const ls = hasHead ? (await this.git.run(['ls-tree', 'HEAD', '--', lit(p.path)])).trim() : '';
        const mode = ls ? ls.split(/\s/)[0] : '100644';
        await this.git.run(['update-index', '--add', '--cacheinfo', `${mode},${sha},${p.path}`], { env, log: true });
      }
      const args = ['commit', '-F', msgFile];
      if (o.amend) args.push('--amend');
      if (o.signOff) args.push('--signoff');
      await this.git.run(args, { env, log: true });
      // Sync the real index for the committed paths with the new HEAD; the
      // unselected lines stay as unstaged changes in the working tree.
      if (allPaths.length) {
        await this.git.run(['reset', '-q', '--pathspec-from-file=-', '--pathspec-file-nul'],
          { stdin: `${allPaths.map(lit).join('\0')}\0`, log: true });
      }
    } finally {
      for (const f of [tmpIndex, `${tmpIndex}.lock`, msgFile]) {
        try { fs.rmSync(f, { force: true }); } catch { /* ignore */ }
      }
    }
  }

  /** Reverts tracked changes to HEAD. */
  async rollback(changes, hasHead, deleteAdded) {
    const all = (list) => list.flatMap((c) => (c.oldPath ? [c.path, c.oldPath] : [c.path])).map(lit);
    if (!hasHead) {
      await this.git.run(['rm', '-r', '--cached', '-q', '--', ...all(changes)], { log: true });
      return;
    }
    const added = changes.filter((c) => c.type === 'added');
    const others = changes.filter((c) => c.type !== 'added');
    if (others.length) {
      await this.git.run(['restore', '--source=HEAD', '--staged', '--worktree', '--', ...all(others)], { log: true });
    }
    if (added.length) {
      await this.git.run(['rm', '--cached', '-q', '-f', '--', ...added.map((c) => lit(c.path))], { log: true });
      if (deleteAdded) for (const c of added) fs.rmSync(path.join(this.root, c.path), { force: true });
    }
  }

  async acceptSide(change, ours) {
    const code = change.conflictCode || 'UU';
    const deleted = ours ? code === 'DU' || code === 'DD' : code === 'UD' || code === 'DD';
    if (deleted) {
      await this.git.run(['rm', '-q', '--', lit(change.path)], { log: true });
      return;
    }
    await this.git.run(['checkout', ours ? '--ours' : '--theirs', '--', lit(change.path)], { log: true });
    await this.git.run(['add', '--', lit(change.path)], { log: true });
  }

  async markResolved(filePath) {
    await this.git.run(['add', '--', lit(filePath)], { log: true });
  }

  continueOperation(state) {
    const args = {
      merging: ['commit', '--no-edit'],
      rebasing: ['rebase', '--continue'],
      cherryPicking: ['cherry-pick', '--continue'],
      reverting: ['revert', '--continue'],
    }[state];
    return this.git.run(args, { log: true });
  }

  abortOperation(state) {
    const op = { merging: 'merge', rebasing: 'rebase', cherryPicking: 'cherry-pick', reverting: 'revert' }[state];
    return this.git.run([op, '--abort'], { log: true });
  }
}

module.exports = {
  GitRunner, Repository, GitError, lit, parseStatus, parseCommits, parseRefs, parseNameStatus, splitN,
};
