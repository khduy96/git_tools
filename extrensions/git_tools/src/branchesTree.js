// @ts-check
'use strict';

const vscode = require('vscode');

/**
 * Tree of HEAD, local / remote branches, tags and stashes.
 */
class BranchesTreeProvider {
  /** @param {import('./model').RepoManager} manager */
  constructor(manager) {
    this.manager = manager;
    this._onDidChange = new vscode.EventEmitter();
    this.onDidChangeTreeData = this._onDidChange.event;
    manager.onDidChange((what) => {
      if (what === 'refs' || what === 'status') this._onDidChange.fire(undefined);
    });
    manager.onDidChangeCurrent(() => this._onDidChange.fire(undefined));
  }

  getTreeItem(el) {
    return el.item;
  }

  getChildren(el) {
    const m = this.manager.current;
    if (!m) return [];
    if (!el) return this.roots(m);
    return el.children || [];
  }

  /** @param {import('./model').RepoModel} m */
  roots(m) {
    const s = m.status;
    const head = new vscode.TreeItem(
      s.branch ? `HEAD (${s.branch})` : `HEAD (detached at ${s.head ? s.head.slice(0, 8) : '?'})`,
      vscode.TreeItemCollapsibleState.None);
    head.iconPath = new vscode.ThemeIcon('target', new vscode.ThemeColor('charts.yellow'));
    head.description = [s.ahead ? `↑${s.ahead}` : '', s.behind ? `↓${s.behind}` : '', s.upstream || ''].filter(Boolean).join(' ');
    head.command = { command: 'gitTools.branch.showLog', title: 'Show in Log', arguments: [{ branch: { name: 'HEAD' } }] };

    const local = m.branches.filter((b) => !b.remote);
    const remote = m.branches.filter((b) => b.remote);
    const byRemote = new Map();
    for (const b of remote) {
      const r = b.name.slice(0, b.name.indexOf('/'));
      if (!byRemote.has(r)) byRemote.set(r, []);
      byRemote.get(r).push(b);
    }

    return [
      { item: head },
      this.group('Local', 'folder', local.map((b) => this.branchNode(b, b.name)), true),
      this.group('Remote', 'cloud', [...byRemote].map(([r, list]) =>
        this.group(r, 'cloud', list.map((b) => this.branchNode(b, b.name.slice(r.length + 1))), false)), true),
      this.group('Tags', 'tag', m.tags.map((t) => this.tagNode(t)), false),
      this.group('Stashes', 'archive', m.stashes.map((st) => this.stashNode(st)), false),
    ];
  }

  group(label, icon, children, expanded) {
    const item = new vscode.TreeItem(label,
      expanded ? vscode.TreeItemCollapsibleState.Expanded : vscode.TreeItemCollapsibleState.Collapsed);
    item.iconPath = new vscode.ThemeIcon(icon);
    item.description = String(children.length);
    item.contextValue = 'group';
    return { item, children };
  }

  /** @param {import('./git').Branch} b */
  branchNode(b, label) {
    const item = new vscode.TreeItem(label, vscode.TreeItemCollapsibleState.None);
    const fav = /(^|\/)(main|master|develop)$/.test(b.name);
    item.iconPath = b.current
      ? new vscode.ThemeIcon('tag', new vscode.ThemeColor('charts.yellow'))
      : fav ? new vscode.ThemeIcon('star-full', new vscode.ThemeColor('charts.yellow'))
        : new vscode.ThemeIcon('git-branch', new vscode.ThemeColor(b.remote ? 'charts.purple' : 'charts.green'));
    item.description = [b.ahead ? `↑${b.ahead}` : '', b.behind ? `↓${b.behind}` : '', b.gone ? 'gone' : ''].filter(Boolean).join(' ');
    item.tooltip = `${b.name}${b.upstream ? `\nTracking ${b.upstream}` : ''}\n${b.hash.slice(0, 10)}`;
    item.contextValue = b.current ? 'branch-current' : b.remote ? 'branch-remote' : 'branch-local';
    item.command = { command: 'gitTools.branch.showLog', title: 'Show in Log', arguments: [{ branch: b }] };
    return { item, branch: b };
  }

  tagNode(t) {
    const item = new vscode.TreeItem(t.name, vscode.TreeItemCollapsibleState.None);
    item.iconPath = new vscode.ThemeIcon('tag', new vscode.ThemeColor('charts.blue'));
    item.description = t.hash.slice(0, 8);
    item.contextValue = 'tag';
    // Branch-like object so shared commands (new branch, merge) work on tags.
    const asBranch = { name: `refs/tags/${t.name}`, remote: false, current: false, hash: t.hash, upstream: null, ahead: 0, behind: 0, gone: false };
    item.command = { command: 'gitTools.branch.showLog', title: 'Show in Log', arguments: [{ branch: asBranch }] };
    return { item, tag: t, branch: asBranch };
  }

  stashNode(st) {
    const item = new vscode.TreeItem(st.message, vscode.TreeItemCollapsibleState.None);
    item.iconPath = new vscode.ThemeIcon('archive');
    item.description = st.ref;
    item.tooltip = `${st.ref}\n${st.message}\n${new Date(st.time).toLocaleString()}`;
    item.contextValue = 'stash';
    item.command = { command: 'gitTools.stash.showFiles', title: 'Show Changes', arguments: [{ stash: st }] };
    return { item, stash: st };
  }
}

/**
 * Status bar entry with the current branch (opens the branches popup).
 */
class BranchStatusBar {
  /** @param {import('./model').RepoManager} manager */
  constructor(manager) {
    this.manager = manager;
    this.item = vscode.window.createStatusBarItem('gitTools.branch', vscode.StatusBarAlignment.Left, 50);
    this.item.name = 'Git Tools Branch';
    this.item.command = 'gitTools.branches';
    manager.onDidChange(() => this.update());
    manager.onDidChangeCurrent(() => this.update());
    this.update();
  }

  update() {
    const m = this.manager.current;
    if (!m) {
      this.item.hide();
      return;
    }
    const s = m.status;
    const name = s.branch || (s.head ? s.head.slice(0, 8) : 'no commits');
    const sync = [s.ahead ? `${s.ahead}↑` : '', s.behind ? `${s.behind}↓` : ''].filter(Boolean).join(' ');
    const multi = this.manager.models.size > 1 ? `${m.name}: ` : '';
    this.item.text = `${m.busy ? '$(sync~spin)' : '$(git-branch)'} ${multi}${name}${sync ? ` ${sync}` : ''}`;
    this.item.tooltip = m.busy ? `${m.busy}…` : `Git Tools · ${m.name}\nBranch: ${name}${s.upstream ? `\nTracking ${s.upstream}` : ''}\nClick for branches and actions`;
    this.item.show();
  }

  dispose() {
    this.item.dispose();
  }
}

module.exports = { BranchesTreeProvider, BranchStatusBar };
