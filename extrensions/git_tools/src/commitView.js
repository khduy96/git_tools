// @ts-check
'use strict';

const vscode = require('vscode');
const path = require('path');
const { webviewHtml } = require('./webview');
const { openLocalDiff } = require('./diff');
const cmd = require('./commands');

/**
 * Webview view "Commit": changes with checkboxes and the commit message.
 */
class CommitViewProvider {
  /**
   * @param {vscode.ExtensionContext} context
   * @param {import('./model').RepoManager} manager
   * @param {import('./aiCommands').AiController} ai
   */
  constructor(context, manager, ai) {
    this.context = context;
    this.manager = manager;
    this.ai = ai;
    /** @type {vscode.WebviewView|null} */
    this.view = null;
    manager.onDidChange((what) => {
      if (what === 'message') this.postMessageText(true);
      else if (what !== 'log') this.postState();
    });
    manager.onDidChangeCurrent(() => this.postState());
    ai.onDidChange(() => this.postState());
    /** @type {'none'|'directory'} */
    this.groupBy = context.globalState.get('gitTools.commit.groupBy', 'none');
    vscode.commands.executeCommand('setContext', 'gitTools.commitGroupBy', this.groupBy);
  }

  /** @param {'none'|'directory'} value */
  setGroupBy(value) {
    this.groupBy = value;
    this.context.globalState.update('gitTools.commit.groupBy', value);
    vscode.commands.executeCommand('setContext', 'gitTools.commitGroupBy', value);
    this.postState();
  }

  /** @param {vscode.WebviewView} view */
  resolveWebviewView(view) {
    this.view = view;
    view.webview.options = { enableScripts: true, localResourceRoots: [vscode.Uri.joinPath(this.context.extensionUri, 'media')] };
    view.webview.html = webviewHtml(view.webview, this.context.extensionUri, {
      title: 'Commit',
      styles: ['commit.css'],
      scripts: ['common.js', 'commit.js'],
    });
    view.webview.onDidReceiveMessage((msg) => this.onMessage(msg));
    view.onDidChangeVisibility(() => { if (view.visible) this.postState(); });
    view.onDidDispose(() => { this.view = null; });
  }

  focusMessage() {
    if (this.view) {
      this.view.show(false);
      this.view.webview.postMessage({ type: 'focusMessage' });
    }
  }

  postState() {
    if (!this.view) return;
    const m = this.manager.current;
    this.view.description = m && this.manager.models.size > 1 ? m.name : undefined;
    this.view.webview.postMessage({
      type: 'state',
      state: m ? {
        repo: m.name,
        multiRepo: this.manager.models.size > 1,
        groupBy: this.groupBy,
        repoState: m.status.state,
        hasCommits: !!m.status.head,
        changes: m.status.changes.map((c) => ({ ...c, included: c.type !== 'conflicted' && m.isIncluded(c) })),
        message: m.message,
        amend: m.amend,
        busy: m.busy,
        generating: this.ai.generating,
        aiReady: this.ai.isConfigured(),
        aiModel: this.ai.model(),
      } : { repo: null, groupBy: this.groupBy, repoState: 'normal', changes: [], message: '' },
    });
  }

  postMessageText(force) {
    const m = this.manager.current;
    if (this.view && m) this.view.webview.postMessage({ type: 'message', text: m.message, force });
  }

  async onMessage(msg) {
    const m = this.manager.current;
    if (msg.type === 'ready') return this.postState();
    if (!m) return;
    const byPath = new Map(m.status.changes.map((c) => [c.path, c]));
    const changes = (msg.paths || []).map((p) => byPath.get(p)).filter(Boolean);
    switch (msg.type) {
      case 'toggle':
        return m.setIncluded(msg.paths, msg.value);
      case 'open': {
        const c = byPath.get(msg.path);
        if (c) await openLocalDiff(m, c, msg.preview);
        return;
      }
      case 'message':
        return m.setMessage(msg.text);
      case 'amend':
        m.amend = msg.value;
        if (m.amend && !m.message.trim() && m.status.head) {
          m.message = await m.repo.lastCommitMessage();
          this.postMessageText(true);
        }
        return this.postState();
      case 'commit':
        return m.commit({ push: msg.push });
      case 'generate':
        return this.ai.generate();
      case 'cancelGenerate':
        return this.ai.cancel();
      case 'resolve':
        return vscode.commands.executeCommand('gitTools.resolveConflicts');
      case 'continue':
        return vscode.commands.executeCommand('gitTools.continueOperation');
      case 'abort':
        return vscode.commands.executeCommand('gitTools.abortOperation');
      case 'menu':
        return this.menuAction(m, msg.action, changes);
      case 'addToVcs':
        return cmd.addToVcs(m, changes);
      case 'unversion':
        return cmd.unversion(m, changes);
    }
  }

  /** @param {import('./model').RepoModel} m */
  async menuAction(m, action, changes) {
    const first = changes[0];
    switch (action) {
      case 'diff':
        for (const c of changes.slice(0, 10)) if (c.type !== 'conflicted') await openLocalDiff(m, c, false);
        return;
      case 'openFile':
        return vscode.window.showTextDocument(vscode.Uri.file(path.join(m.root, first.path)));
      case 'resolve':
        return vscode.commands.executeCommand('gitTools.resolveConflicts');
      case 'include':
      case 'exclude':
        return m.setIncluded(changes.map((c) => c.path), action === 'include');
      case 'rollback':
        return cmd.rollback(m, changes);
      case 'delete':
        return cmd.deleteUntracked(m, changes);
      case 'ignore':
        return cmd.addToGitignore(m, changes);
      case 'addToVcs':
        return cmd.addToVcs(m, changes);
      case 'history':
        m.setLogFilter({ path: first.path, branch: null });
        return vscode.commands.executeCommand('gitTools.log.focus');
      case 'copy':
        await vscode.env.clipboard.writeText(changes.map((c) => c.path).join('\n'));
        return vscode.window.setStatusBarMessage('Path copied', 3000);
      case 'reveal':
        return vscode.commands.executeCommand('revealInExplorer', vscode.Uri.file(path.join(m.root, first.path)));
    }
  }
}

module.exports = { CommitViewProvider };
