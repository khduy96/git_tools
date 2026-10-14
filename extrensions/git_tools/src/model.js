// @ts-check
'use strict';

const vscode = require('vscode');
const path = require('path');
const { Repository, GitError } = require('./git');
const { layoutGraph } = require('./graph');

/**
 * State of one repository, shared by all views.
 */
class RepoModel {
  /**
   * @param {string} root
   * @param {vscode.OutputChannel} output
   */
  constructor(root, output) {
    this.output = output;
    const cfg = vscode.workspace.getConfiguration('gitTools');
    this.repo = new Repository(root, {
      gitPath: cfg.get('gitPath') || 'git',
      log: (line, kind) => this.log(line, kind),
    });
    /** @type {import('./git').Status} */
    this.status = { branch: null, head: null, upstream: null, ahead: 0, behind: 0, changes: [], state: 'normal' };
    /** @type {import('./git').Branch[]} */
    this.branches = [];
    /** @type {{name: string, hash: string}[]} */
    this.tags = [];
    /** @type {{name: string, url: string}[]} */
    this.remotes = [];
    /** @type {any[]} */
    this.stashes = [];
    /** @type {import('./git').Commit[]} */
    this.commits = [];
    /** @type {ReturnType<typeof layoutGraph>} */
    this.graph = [];
    /** @type {{branch: string|null, path: string|null}} */
    this.logFilter = { branch: null, path: null };
    this.logLoading = false;

    /** Commit message shown in the Commit view. */
    this.message = '';
    this.amend = false;
    this._prefilled = null;

    // Checkbox model: tracked files are included unless excluded,
    // unversioned files are excluded unless included.
    /** @type {Set<string>} */
    this.excludedTracked = new Set();
    /** @type {Set<string>} */
    this.includedUntracked = new Set();

    /** @type {string|null} */
    this.busy = null;

    this._onDidChange = new vscode.EventEmitter();
    /** Fires with 'status' | 'refs' | 'log' | 'message' | 'busy'. */
    this.onDidChange = this._onDidChange.event;

    /** @type {vscode.Disposable[]} */
    this.disposables = [this._onDidChange];
    this._timer = null;
    this._refsDirty = false;
    this._logGen = 0;
    this._started = false;
  }

  get root() {
    return this.repo.root;
  }

  get name() {
    return this.repo.name;
  }

  log(line, kind = 'info') {
    const t = new Date();
    const pad = (n) => String(n).padStart(2, '0');
    const stamp = `${pad(t.getHours())}:${pad(t.getMinutes())}:${pad(t.getSeconds())}`;
    const prefix = kind === 'command' ? `${stamp} > ` : kind === 'output' ? '    ' : kind === 'error' ? `${stamp} ! ` : `${stamp}   `;
    this.output.appendLine(prefix + line);
  }

  fire(what) {
    this._onDidChange.fire(what);
  }

  async start() {
    await this.refreshAll();
    const msg = await this.repo.pendingMergeMessage().catch(() => null);
    if (msg && !this.message) {
      this.message = msg;
      this._prefilled = msg;
      this.fire('message');
    }
    this.watch();
  }

  dispose() {
    for (const d of this.disposables) d.dispose();
    if (this._timer) clearTimeout(this._timer);
  }

  // ------------------------------------------------------------- watching

  watch() {
    if (!vscode.workspace.getConfiguration('gitTools').get('autoRefresh')) return;
    const onFile = (uri) => {
      const rel = path.relative(this.root, uri.fsPath).replace(/\\/g, '/');
      if (rel.startsWith('..')) return;
      if (rel === '.git' || rel.startsWith('.git/')) {
        if (rel.endsWith('.lock') || rel.startsWith('.git/objects') || rel.startsWith('.git/logs')) return;
        if (rel.startsWith('.git/refs') || /^\.git\/(HEAD|packed-refs|FETCH_HEAD|MERGE_HEAD|ORIG_HEAD)$/.test(rel) || rel.startsWith('.git/rebase-')) {
          this._refsDirty = true;
        } else if (rel !== '.git/index') {
          return;
        }
      }
      this.scheduleRefresh();
    };
    const w = vscode.workspace.createFileSystemWatcher(new vscode.RelativePattern(this.root, '**'));
    w.onDidChange(onFile);
    w.onDidCreate(onFile);
    w.onDidDelete(onFile);
    this.disposables.push(w);
    this.disposables.push(vscode.window.onDidChangeWindowState((s) => {
      if (s.focused) {
        this._refsDirty = true;
        this.scheduleRefresh();
      }
    }));
  }

  scheduleRefresh() {
    if (this._timer) clearTimeout(this._timer);
    this._timer = setTimeout(() => {
      this._timer = null;
      if (this.busy) return; // refreshed when the operation ends
      if (this._refsDirty) {
        this._refsDirty = false;
        this.refreshAll();
      } else {
        this.refreshStatus();
      }
    }, 600);
  }

  // ------------------------------------------------------------- refresh

  async refreshAll() {
    await Promise.all([this.refreshStatus(), this.refreshRefs()]);
    await this.refreshLog();
  }

  async refreshStatus() {
    try {
      const previous = this.status.state;
      this.status = await this.repo.status();
      const paths = new Set(this.status.changes.map((c) => c.path));
      for (const p of [...this.excludedTracked]) if (!paths.has(p)) this.excludedTracked.delete(p);
      for (const p of [...this.includedUntracked]) if (!paths.has(p)) this.includedUntracked.delete(p);
      // Prefill the prepared message when a merge / cherry-pick starts and
      // clear it again when the operation ends elsewhere.
      if (previous === 'normal' && this.status.state !== 'normal' && !this.message.trim()) {
        const msg = await this.repo.pendingMergeMessage();
        if (msg) {
          this.message = msg;
          this._prefilled = msg;
          this.fire('message');
        }
      } else if (this.status.state === 'normal' && this._prefilled && this.message.trim() === this._prefilled.trim()) {
        this.message = '';
        this._prefilled = null;
        this.fire('message');
      }
      this.fire('status');
    } catch (e) {
      this.log(`status failed: ${e.message}`, 'error');
    }
  }

  async refreshRefs() {
    try {
      const [branches, tags, remotes, stashes] = await Promise.all([
        this.repo.branches(), this.repo.tags(), this.repo.remotes(), this.repo.stashes(),
      ]);
      Object.assign(this, { branches, tags, remotes, stashes });
      this.fire('refs');
    } catch (e) {
      this.log(`refs failed: ${e.message}`, 'error');
    }
  }

  async refreshLog() {
    const gen = ++this._logGen;
    this.logLoading = true;
    this.fire('log');
    try {
      const limit = vscode.workspace.getConfiguration('gitTools').get('log.maxCommits') || 2000;
      const commits = await this.repo.log({
        revisions: this.logFilter.branch ? [this.logFilter.branch] : undefined,
        path: this.logFilter.path || undefined,
        limit: Number(limit),
      });
      if (gen !== this._logGen) return;
      this.commits = commits;
      this.graph = layoutGraph(commits);
    } catch (e) {
      this.log(`log failed: ${e.message}`, 'error');
    } finally {
      if (gen === this._logGen) {
        this.logLoading = false;
        this.fire('log');
      }
    }
  }

  setLogFilter(filter) {
    this.logFilter = { ...this.logFilter, ...filter };
    this.refreshLog();
  }

  // ------------------------------------------------------------- inclusion

  isIncluded(c) {
    return c.type === 'untracked' ? this.includedUntracked.has(c.path) : !this.excludedTracked.has(c.path);
  }

  /** @param {string[]} paths @param {boolean} value */
  setIncluded(paths, value) {
    const byPath = new Map(this.status.changes.map((c) => [c.path, c]));
    for (const p of paths) {
      const c = byPath.get(p);
      if (!c || c.type === 'conflicted') continue;
      if (c.type === 'untracked') {
        if (value) this.includedUntracked.add(p);
        else this.includedUntracked.delete(p);
      } else if (value) this.excludedTracked.delete(p);
      else this.excludedTracked.add(p);
    }
    this.fire('status');
  }

  includedChanges() {
    return this.status.changes.filter((c) => c.type !== 'conflicted' && this.isIncluded(c));
  }

  setMessage(text) {
    this.message = text;
  }

  // ------------------------------------------------------------- operations

  /**
   * Runs a git operation with progress and error reporting.
   * @param {string} label
   * @param {() => Promise<any>} action
   * @param {{success?: string, refresh?: boolean}} [o]
   * @returns {Promise<boolean>}
   */
  async run(label, action, o = {}) {
    this.busy = label;
    this.fire('busy');
    this.log(`${label}…`);
    try {
      await vscode.window.withProgress(
        { location: vscode.ProgressLocation.Window, title: label },
        () => action(),
      );
      if (o.success) vscode.window.setStatusBarMessage(`$(check) ${o.success}`, 4000);
      return true;
    } catch (e) {
      const details = e instanceof GitError ? e.message : String(e && e.message ? e.message : e);
      this.log(`${label} failed: ${details}`, 'error');
      vscode.window.showErrorMessage(`${label} failed: ${details.split('\n').slice(0, 6).join(' ')}`, 'Show Console')
        .then((r) => { if (r) this.output.show(true); });
      return false;
    } finally {
      this.busy = null;
      this.fire('busy');
      if (o.refresh !== false) await this.refreshAll();
    }
  }

  async commit({ push = false, signOff = false } = {}) {
    const message = this.message.trim();
    const s = this.status;
    const inOperation = s.state !== 'normal';
    const changes = this.includedChanges();
    if (!message) {
      vscode.window.showWarningMessage('Commit message is empty.');
      return false;
    }
    if (s.changes.some((c) => c.type === 'conflicted')) {
      vscode.window.showWarningMessage('Resolve all conflicts before committing.');
      return false;
    }
    if (!changes.length && !this.amend && !inOperation) {
      vscode.window.showWarningMessage('No changes selected for commit.');
      return false;
    }
    const paths = [...new Set(changes.flatMap((c) => (c.oldPath ? [c.path, c.oldPath] : [c.path])))];
    const ok = await this.run(this.amend ? 'Amend commit' : 'Commit', () => this.repo.commit({
      message, paths, amend: this.amend, signOff, partial: !inOperation,
    }), {
      success: this.amend ? 'Commit amended' : `${changes.length} file(s) committed`,
    });
    if (ok) {
      this.message = '';
      this._prefilled = null;
      this.amend = false;
      this.excludedTracked.clear();
      this.includedUntracked.clear();
      this.fire('message');
      if (push) await vscode.commands.executeCommand('gitTools.push');
    }
    return ok;
  }

  defaultRemote() {
    const up = this.status.upstream;
    if (up && up.includes('/')) return up.slice(0, up.indexOf('/'));
    if (!this.remotes.length) return null;
    return this.remotes.some((r) => r.name === 'origin') ? 'origin' : this.remotes[0].name;
  }
}

/**
 * Tracks the repositories of the workspace and which one is active.
 */
class RepoManager {
  /** @param {vscode.OutputChannel} output */
  constructor(output) {
    this.output = output;
    /** @type {Map<string, RepoModel>} */
    this.models = new Map();
    /** @type {RepoModel|null} */
    this.current = null;
    this._onDidChangeCurrent = new vscode.EventEmitter();
    this.onDidChangeCurrent = this._onDidChangeCurrent.event;
    /** Forwards change events of the current model. */
    this._onDidChange = new vscode.EventEmitter();
    this.onDidChange = this._onDidChange.event;
    this._sub = null;
  }

  async discover() {
    const gitPath = vscode.workspace.getConfiguration('gitTools').get('gitPath') || 'git';
    const roots = new Set();
    for (const f of vscode.workspace.workspaceFolders || []) {
      const root = await Repository.findRoot(f.uri.fsPath, gitPath);
      if (root) roots.add(root);
    }
    for (const root of roots) {
      if (!this.models.has(root)) this.models.set(root, new RepoModel(root, this.output));
    }
    for (const [root, m] of this.models) {
      if (!roots.has(root)) {
        m.dispose();
        this.models.delete(root);
      }
    }
    if (!this.current || !this.models.has(this.current.root)) {
      const first = this.models.values().next().value || null;
      await this.setCurrent(first);
    }
  }

  /** @param {RepoModel|null} m */
  async setCurrent(m) {
    if (this.current === m) return;
    if (this._sub) this._sub.dispose();
    this.current = m;
    this._sub = m ? m.onDidChange((w) => this._onDidChange.fire(w)) : null;
    if (m && !m._started) {
      m._started = true;
      await m.start();
    }
    this._onDidChangeCurrent.fire(m);
  }

  /** Adds a repository by folder path (e.g. opened through the picker). */
  async open(dir) {
    const gitPath = vscode.workspace.getConfiguration('gitTools').get('gitPath') || 'git';
    const root = await Repository.findRoot(dir, gitPath);
    if (!root) return null;
    let m = this.models.get(root);
    if (!m) {
      m = new RepoModel(root, this.output);
      this.models.set(root, m);
    }
    await this.setCurrent(m);
    return m;
  }

  dispose() {
    for (const m of this.models.values()) m.dispose();
    if (this._sub) this._sub.dispose();
    this._onDidChange.dispose();
    this._onDidChangeCurrent.dispose();
  }
}

module.exports = { RepoModel, RepoManager };
