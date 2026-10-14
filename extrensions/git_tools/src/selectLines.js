// @ts-check
'use strict';

const vscode = require('vscode');
const path = require('path');
const { webviewHtml } = require('./webview');
const { parseDiff, changeKeys, describe, remap } = require('./lineSelection');
const { openLocalDiff } = require('./diff');

/** @type {Map<string, LinesPanel>} open panels by repo root + path */
const panels = new Map();

class LinesPanel {
  /**
   * @param {vscode.ExtensionContext} context
   * @param {import('./model').RepoModel} model
   * @param {string} filePath
   */
  constructor(context, model, filePath) {
    this.context = context;
    this.model = model;
    this.filePath = filePath;
    /** @type {import('./lineSelection').ParsedDiff|null} */
    this.parsed = null;
    this.panel = vscode.window.createWebviewPanel('gitTools.lines', `Commit Lines: ${path.basename(filePath)}`,
      vscode.ViewColumn.Active, {
        enableScripts: true,
        retainContextWhenHidden: true,
        localResourceRoots: [vscode.Uri.joinPath(context.extensionUri, 'media')],
      });
    this.panel.webview.html = webviewHtml(this.panel.webview, context.extensionUri, {
      title: 'Select Lines',
      styles: ['lines.css'],
      scripts: ['common.js', 'lines.js'],
    });
    this.panel.webview.onDidReceiveMessage((msg) => this.onMessage(msg));
    const sub = model.onDidChange((what) => {
      if (what === 'status') this.reload();
    });
    this.panel.onDidDispose(() => {
      sub.dispose();
      panels.delete(LinesPanel.key(model, filePath));
    });
  }

  static key(model, filePath) {
    return `${model.root}|${filePath}`;
  }

  /** Loads (or reloads after a file change) the diff and current selection. */
  async reload() {
    const change = this.model.status.changes.find((c) => c.path === this.filePath);
    if (!this.model.canSelectLines(change)) {
      this.post({ type: 'gone', reason: change ? 'Only modified files can be committed line by line.' : 'The file has no changes anymore.' });
      return;
    }
    const parsed = parseDiff(await this.model.repo.fileDiff(this.filePath));
    if (parsed.binary || !parsed.hunks.length) {
      this.post({ type: 'gone', reason: parsed.binary ? 'Binary files cannot be committed line by line.' : 'The file has no textual changes.' });
      return;
    }
    const sel = this.model.lineSelections.get(this.filePath);
    const fileExcluded = this.model.excludedTracked.has(this.filePath);
    let excluded;
    if (fileExcluded) {
      excluded = changeKeys(parsed);
    } else if (!sel) {
      excluded = [];
    } else if (sel.signature === parsed.signature) {
      excluded = [...sel.excluded];
    } else {
      // The file was edited: keep the selection for lines that still exist.
      const prev = this.parsed && this.parsed.signature === sel.signature ? this.parsed : null;
      excluded = prev ? remap(parsed, describe(prev, sel.excluded)) : [];
      this.model.setLineSelection(this.filePath, parsed.signature, excluded, changeKeys(parsed).length);
    }
    // Re-render only when the diff or the effective selection differs from
    // what the panel shows (its own clicks come back here unchanged).
    const shown = JSON.stringify([parsed.signature, [...excluded].sort()]);
    this.parsed = parsed;
    if (shown !== this._shown) {
      this._shown = shown;
      this.post({ type: 'init', path: this.filePath, hunks: parsed.hunks, excluded });
    }
  }

  post(msg) {
    this.panel.webview.postMessage(msg);
  }

  async onMessage(msg) {
    switch (msg.type) {
      case 'ready':
        this.parsed = null;
        this._shown = null;
        return this.reload();
      case 'selection':
        if (!this.parsed) return;
        this._shown = JSON.stringify([this.parsed.signature, [...msg.excluded].sort()]);
        this.model.setLineSelection(this.filePath, this.parsed.signature, msg.excluded, changeKeys(this.parsed).length);
        return;
      case 'openDiff': {
        const c = this.model.status.changes.find((x) => x.path === this.filePath);
        if (c) await openLocalDiff(this.model, c, false);
        return;
      }
      case 'openFile':
        return vscode.window.showTextDocument(vscode.Uri.file(path.join(this.model.root, this.filePath)));
      case 'commit':
        return vscode.commands.executeCommand('gitTools.focusCommit');
    }
  }
}

/**
 * Opens the line selection panel for a modified file.
 * @param {vscode.ExtensionContext} context
 * @param {import('./model').RepoModel} model
 * @param {string} filePath
 */
async function openLineSelection(context, model, filePath) {
  const change = model.status.changes.find((c) => c.path === filePath);
  if (!model.canSelectLines(change)) {
    vscode.window.showInformationMessage('Only modified files that exist in HEAD can be committed line by line.');
    return;
  }
  const key = LinesPanel.key(model, filePath);
  const existing = panels.get(key);
  if (existing) {
    existing.panel.reveal();
    return;
  }
  panels.set(key, new LinesPanel(context, model, filePath));
}

module.exports = { openLineSelection };
