// @ts-check
'use strict';

const vscode = require('vscode');
const path = require('path');
const { webviewHtml } = require('./webview');
const cmd = require('./commands');

const STATE_LABEL = {
  merging: 'MERGING',
  rebasing: 'REBASING',
  cherryPicking: 'CHERRY-PICKING',
  reverting: 'REVERTING',
};

/** Commands run for the row actions (they accept {model} as argument). */
const ACTIONS = {
  fetch: 'gitTools.fetch',
  update: 'gitTools.update',
  push: 'gitTools.push',
  refresh: 'gitTools.refresh',
  terminal: 'gitTools.repo.openTerminal',
  reveal: 'gitTools.repo.revealInOS',
  close: 'gitTools.repo.close',
};

/**
 * "Source Control Repositories": each repository with a branch widget
 * (⑂ branch ↑ahead ↓behind ▾) that opens the branches popup.
 */
class RepositoriesViewProvider {
  /**
   * @param {vscode.ExtensionContext} context
   * @param {import('./model').RepoManager} manager
   */
  constructor(context, manager) {
    this.context = context;
    this.manager = manager;
    /** @type {vscode.WebviewView|null} */
    this.view = null;
    this._timer = null;
    // Coalesce bursts of status events from several repositories.
    manager.onDidChangeRepositories(() => {
      if (this._timer) return;
      this._timer = setTimeout(() => {
        this._timer = null;
        this.post();
      }, 150);
    });
  }

  /** @param {vscode.WebviewView} view */
  resolveWebviewView(view) {
    this.view = view;
    view.webview.options = { enableScripts: true, localResourceRoots: [vscode.Uri.joinPath(this.context.extensionUri, 'media')] };
    view.webview.html = webviewHtml(view.webview, this.context.extensionUri, {
      title: 'Source Control Repositories',
      styles: ['repos.css'],
      scripts: ['common.js', 'repos.js'],
    });
    view.webview.onDidReceiveMessage((msg) => this.onMessage(msg));
    view.onDidChangeVisibility(() => { if (view.visible) this.post(); });
    view.onDidDispose(() => { this.view = null; });
  }

  post() {
    if (!this.view) return;
    const folders = (vscode.workspace.workspaceFolders || []).map((f) => f.uri.fsPath);
    const repos = this.manager.list().map((m) => {
      const s = m.status;
      const parent = folders.find((f) => m.root.toLowerCase().startsWith(f.toLowerCase() + path.sep));
      return {
        root: m.root,
        name: m.name,
        relPath: parent ? path.relative(parent, m.root).replace(/\\/g, '/') : '',
        current: this.manager.current === m,
        branchLabel: s.branch || (s.head ? `Detached ${s.head.slice(0, 8)}` : 'No commits'),
        upstream: s.upstream,
        ahead: s.ahead,
        behind: s.behind,
        changes: s.changes.length,
        conflicts: s.changes.filter((c) => c.type === 'conflicted').length,
        state: STATE_LABEL[s.state] || '',
        busy: m.busy,
      };
    });
    this.view.webview.postMessage({ type: 'repos', repos });
  }

  async onMessage(msg) {
    if (msg.type === 'ready') return this.post();
    const m = this.manager.get(msg.root);
    if (!m) return;
    switch (msg.type) {
      case 'select':
        return this.manager.setCurrent(m);
      case 'branches':
        await this.manager.setCurrent(m);
        return cmd.branchesPopup(m);
      case 'action':
        if (ACTIONS[msg.action]) return vscode.commands.executeCommand(ACTIONS[msg.action], { model: m });
    }
  }
}

module.exports = { RepositoriesViewProvider };
