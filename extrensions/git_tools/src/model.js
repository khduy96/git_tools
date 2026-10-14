// @ts-check
'use strict';

const vscode = require('vscode');
const fs = require('fs');
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
    /**
     * Files committed partially: path → excluded line keys of its diff.
     * @type {Map<string, {signature: string, excluded: Set<string>, total: number}>}
     */
    this.lineSelections = new Map();

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
    /** True once refs and log are loaded (repository was selected). */
    this._full = false;
    this._watching = false;
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
    this._full = true;
    await this.refreshAll();
    const msg = await this.repo.pendingMergeMessage().catch(() => null);
    if (msg && !this.message) {
      this.message = msg;
      this._prefilled = msg;
      this.fire('message');
    }
    this.watch();
  }

  /** Status only, for repositories that are listed but not selected. */
  async startLight() {
    await this.refreshStatus();
    this.watch();
  }

  dispose() {
    for (const d of this.disposables) d.dispose();
    if (this._timer) clearTimeout(this._timer);
  }

  // ------------------------------------------------------------- watching

  watch() {
    if (this._watching || !vscode.workspace.getConfiguration('gitTools').get('autoRefresh')) return;
    this._watching = true;
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
      if (this._refsDirty && this._full) {
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
      for (const p of [...this.lineSelections.keys()]) {
        const c = this.status.changes.find((x) => x.path === p);
        if (!this.canSelectLines(c)) this.lineSelections.delete(p);
      }
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
      // Ticking / unticking the whole file drops a line selection.
      this.lineSelections.delete(p);
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

  // ------------------------------------------------------------- line selection

  /** Whether lines of this change can be selected individually. */
  canSelectLines(c) {
    return !!c && c.type === 'modified' && !!this.status.head;
  }

  /**
   * Stores which changed lines of `filePath` are left out of the commit.
   * An empty set means the whole file; all keys excluded means nothing.
   * @param {string} filePath
   * @param {string} signature diff signature the keys belong to
   * @param {string[]} excluded
   * @param {number} total number of changed lines
   */
  setLineSelection(filePath, signature, excluded, total) {
    if (!excluded.length) {
      this.lineSelections.delete(filePath);
      this.excludedTracked.delete(filePath);
    } else if (excluded.length >= total) {
      this.lineSelections.delete(filePath);
      this.excludedTracked.add(filePath);
    } else {
      this.lineSelections.set(filePath, { signature, excluded: new Set(excluded), total });
      this.excludedTracked.delete(filePath);
    }
    this.fire('status');
  }

  /**
   * Content to commit for every included file with a line selection.
   * Throws when a file changed since its lines were selected.
   */
  async selectedContents() {
    const { parseDiff, buildContent } = require('./lineSelection');
    const result = [];
    for (const c of this.includedChanges()) {
      const sel = this.lineSelections.get(c.path);
      if (!sel) continue;
      const parsed = parseDiff(await this.repo.fileDiff(c.path));
      if (parsed.signature !== sel.signature) {
        const err = new Error(`${c.path} changed after its lines were selected. Review the selection again.`);
        /** @type {any} */ (err).path = c.path;
        throw err;
      }
      const head = await this.repo.show('HEAD', c.path);
      result.push({ path: c.path, content: buildContent(head ? head.toString('utf8') : '', parsed, sel.excluded), parsed, sel });
    }
    return result;
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
    const hasLines = changes.some((c) => this.lineSelections.has(c.path));
    if (hasLines && inOperation) {
      vscode.window.showWarningMessage('Selecting individual lines is not possible while a merge or rebase is in progress. Include whole files instead.');
      return false;
    }
    let partial = [];
    if (hasLines) {
      try {
        partial = await this.selectedContents();
      } catch (e) {
        const r = await vscode.window.showWarningMessage(e.message, 'Select Lines…');
        if (r && e.path) vscode.commands.executeCommand('gitTools.selectLines', { model: this, path: e.path });
        return false;
      }
    }
    const partialPaths = new Set(partial.map((p) => p.path));
    const ok = await this.run(this.amend ? 'Amend commit' : 'Commit', () => (hasLines
      ? this.repo.commitSelected({
        message,
        fullPaths: paths.filter((p) => !partialPaths.has(p)),
        partial: partial.map((p) => ({ path: p.path, content: p.content })),
        amend: this.amend,
        signOff,
      })
      : this.repo.commit({ message, paths, amend: this.amend, signOff, partial: !inOperation })), {
      success: this.amend ? 'Commit amended'
        : `${changes.length} file(s) committed${partial.length ? ` (${partial.length} partially)` : ''}`,
    });
    if (ok) {
      this.message = '';
      this._prefilled = null;
      this.amend = false;
      this.excludedTracked.clear();
      this.includedUntracked.clear();
      this.lineSelections.clear();
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
const SCAN_SKIP = new Set(['node_modules', '.dart_tool', 'build', '.gradle', '.idea', '.vscode', 'Pods', 'dist', 'out', '.git']);

/** Map key for a repository root (case-insensitive on Windows). */
const keyOf = (root) => (process.platform === 'win32' ? root.toLowerCase() : root);

/**
 * Tracks the repositories of the workspace and which one is active.
 */
class RepoManager {
  /**
   * @param {vscode.OutputChannel} output
   * @param {vscode.Memento} [state] workspace state for opened / closed repositories
   */
  constructor(output, state) {
    this.output = output;
    this.state = state;
    /** @type {Map<string, RepoModel>} keyed by keyOf(root) */
    this.models = new Map();
    /** @type {RepoModel|null} */
    this.current = null;
    this._onDidChangeCurrent = new vscode.EventEmitter();
    this.onDidChangeCurrent = this._onDidChangeCurrent.event;
    /** Forwards change events of the current model. */
    this._onDidChange = new vscode.EventEmitter();
    this.onDidChange = this._onDidChange.event;
    /** Fires when any repository changes or the list changes. */
    this._onDidChangeRepositories = new vscode.EventEmitter();
    this.onDidChangeRepositories = this._onDidChangeRepositories.event;
    this._sub = null;
    this._discovering = null;
  }

  /** Repositories sorted by name. */
  list() {
    return [...this.models.values()].sort((a, b) => a.name.localeCompare(b.name) || a.root.localeCompare(b.root));
  }

  get(root) {
    return this.models.get(keyOf(root)) || null;
  }

  _stored(name) {
    return this.state ? this.state.get(name, []) : [];
  }

  async _store(name, list) {
    if (this.state) await this.state.update(name, [...new Set(list)]);
  }

  /** Finds repositories in the workspace folders and their sub folders. */
  async discover() {
    if (this._discovering) return this._discovering;
    this._discovering = this._discover().finally(() => { this._discovering = null; });
    return this._discovering;
  }

  async _discover() {
    const cfg = vscode.workspace.getConfiguration('gitTools');
    const gitPath = cfg.get('gitPath') || 'git';
    const depth = Math.max(0, Number(cfg.get('repositoryScanMaxDepth', 1)));
    const candidates = [];
    const scan = (dir, level) => {
      if (level > depth) return;
      let entries = [];
      try {
        entries = fs.readdirSync(dir, { withFileTypes: true });
      } catch {
        return;
      }
      for (const e of entries) {
        if (!e.isDirectory() || SCAN_SKIP.has(e.name)) continue;
        const child = path.join(dir, e.name);
        if (fs.existsSync(path.join(child, '.git'))) candidates.push(child);
        scan(child, level + 1);
      }
    };
    for (const f of vscode.workspace.workspaceFolders || []) {
      candidates.push(f.uri.fsPath);
      scan(f.uri.fsPath, 1);
    }
    candidates.push(...this._stored('gitTools.openedRepos'));

    const closed = new Set(this._stored('gitTools.closedRepos').map(keyOf));
    const roots = new Map();
    for (const dir of candidates) {
      const root = await Repository.findRoot(dir, gitPath);
      if (root && !closed.has(keyOf(root))) roots.set(keyOf(root), root);
    }

    for (const [key, root] of roots) {
      if (!this.models.has(key)) this._add(root);
    }
    for (const [key, m] of this.models) {
      if (!roots.has(key)) this._remove(m);
    }
    if (!this.current || !this.models.has(keyOf(this.current.root))) {
      await this.setCurrent(this.list()[0] || null);
    }
    this._onDidChangeRepositories.fire(undefined);
  }

  _add(root) {
    const m = new RepoModel(root, this.output);
    this.models.set(keyOf(root), m);
    m.disposables.push(m.onDidChange((w) => {
      if (w === 'status' || w === 'busy' || w === 'refs') this._onDidChangeRepositories.fire(undefined);
    }));
    m.startLight();
    return m;
  }

  _remove(m) {
    this.models.delete(keyOf(m.root));
    m.dispose();
  }

  /** @param {RepoModel|null} m */
  async setCurrent(m) {
    if (this.current === m) return;
    if (this._sub) this._sub.dispose();
    this.current = m;
    this._sub = m ? m.onDidChange((w) => this._onDidChange.fire(w)) : null;
    this._onDidChangeRepositories.fire(undefined);
    if (m && !m._started) {
      m._started = true;
      await m.start();
    }
    this._onDidChangeCurrent.fire(m);
  }

  /** Adds a repository by folder path (e.g. opened through the picker). */
  async open(dir, select = true) {
    const gitPath = vscode.workspace.getConfiguration('gitTools').get('gitPath') || 'git';
    const root = await Repository.findRoot(dir, gitPath);
    if (!root) return null;
    await this._store('gitTools.closedRepos', this._stored('gitTools.closedRepos').filter((r) => keyOf(r) !== keyOf(root)));
    const inWorkspace = (vscode.workspace.workspaceFolders || []).some((f) => keyOf(f.uri.fsPath) === keyOf(root));
    if (!inWorkspace) await this._store('gitTools.openedRepos', [...this._stored('gitTools.openedRepos'), root]);
    const m = this.get(root) || this._add(root);
    if (select) await this.setCurrent(m);
    this._onDidChangeRepositories.fire(undefined);
    return m;
  }

  /** Hides a repository from the list (remembered for this workspace). */
  async close(m) {
    await this._store('gitTools.openedRepos', this._stored('gitTools.openedRepos').filter((r) => keyOf(r) !== keyOf(m.root)));
    await this._store('gitTools.closedRepos', [...this._stored('gitTools.closedRepos'), m.root]);
    const wasCurrent = this.current === m;
    this._remove(m);
    if (wasCurrent) {
      this.current = null;
      await this.setCurrent(this.list()[0] || null);
    }
    this._onDidChangeRepositories.fire(undefined);
  }

  /** Re-shows repositories closed earlier. */
  async reopenClosed() {
    await this._store('gitTools.closedRepos', []);
    await this.discover();
  }

  dispose() {
    for (const m of this.models.values()) m.dispose();
    if (this._sub) this._sub.dispose();
    this._onDidChange.dispose();
    this._onDidChangeCurrent.dispose();
    this._onDidChangeRepositories.dispose();
  }
}

module.exports = { RepoModel, RepoManager };
