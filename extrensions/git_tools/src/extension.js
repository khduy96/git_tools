// @ts-check
'use strict';

const vscode = require('vscode');
const path = require('path');
const { RepoManager } = require('./model');
const { RevisionContentProvider, SCHEME } = require('./diff');
const { CommitViewProvider } = require('./commitView');
const { LogViewProvider } = require('./logView');
const { BranchesTreeProvider, BranchStatusBar } = require('./branchesTree');
const { AiController } = require('./aiCommands');
const { openMergeTool } = require('./mergeTool');
const { showSetupGuide } = require('./guide');
const cmd = require('./commands');

/** @param {vscode.ExtensionContext} context */
async function activate(context) {
  const output = vscode.window.createOutputChannel('Git Tools');
  const manager = new RepoManager(output);
  const ai = new AiController(context, manager);
  const commitView = new CommitViewProvider(context, manager, ai);
  const logView = new LogViewProvider(context, manager);
  const branches = new BranchesTreeProvider(manager);
  const statusBar = new BranchStatusBar(manager);

  context.subscriptions.push(
    output,
    statusBar,
    { dispose: () => manager.dispose() },
    vscode.workspace.registerTextDocumentContentProvider(SCHEME, new RevisionContentProvider(manager)),
    vscode.window.registerWebviewViewProvider('gitTools.commit', commitView, { webviewOptions: { retainContextWhenHidden: true } }),
    vscode.window.registerWebviewViewProvider('gitTools.log', logView, { webviewOptions: { retainContextWhenHidden: true } }),
    vscode.window.registerTreeDataProvider('gitTools.branches', branches),
    vscode.workspace.onDidChangeWorkspaceFolders(() => manager.discover()),
    vscode.window.onDidChangeActiveTextEditor((e) => {
      // Follow the repository of the active file when several are open.
      if (!e || e.document.uri.scheme !== 'file' || manager.models.size < 2) return;
      const file = e.document.uri.fsPath.toLowerCase();
      const best = [...manager.models.values()]
        .filter((m) => file.startsWith(m.root.toLowerCase() + path.sep))
        .sort((a, b) => b.root.length - a.root.length)[0];
      if (best && best !== manager.current) manager.setCurrent(best);
    }),
  );

  /** Returns the current repository or explains why there is none. */
  const need = () => {
    const m = manager.current;
    if (!m) vscode.window.showWarningMessage('No Git repository found in this workspace.', 'Select Repository…')
      .then((r) => { if (r) vscode.commands.executeCommand('gitTools.selectRepository'); });
    return m;
  };
  /** Registers a command that needs the current repository. */
  const reg = (id, fn) => context.subscriptions.push(vscode.commands.registerCommand(id, async (...args) => {
    const m = need();
    if (m) return fn(m, ...args);
  }));
  const regFree = (id, fn) => context.subscriptions.push(vscode.commands.registerCommand(id, fn));

  regFree('gitTools.refresh', async () => {
    await manager.discover();
    if (manager.current) await manager.current.refreshAll();
  });
  regFree('gitTools.selectRepository', async () => {
    const items = [...manager.models.values()].map((m) => ({ label: `$(repo) ${m.name}`, description: m.root, model: m }));
    const pick = /** @type {any} */ (await vscode.window.showQuickPick(
      [...items, { label: '$(folder-opened) Open Repository Folder…', id: 'open' }], { title: 'Select Repository' }));
    if (!pick) return;
    if (pick.model) return manager.setCurrent(pick.model);
    const dir = await vscode.window.showOpenDialog({ canSelectFolders: true, canSelectFiles: false, openLabel: 'Open Repository' });
    if (!dir) return;
    if (!(await manager.open(dir[0].fsPath))) vscode.window.showErrorMessage(`${dir[0].fsPath} is not inside a Git repository.`);
  });
  regFree('gitTools.focusCommit', async () => {
    await vscode.commands.executeCommand('gitTools.commit.focus');
    commitView.focusMessage();
  });
  regFree('gitTools.showLog', () => vscode.commands.executeCommand('gitTools.log.focus'));
  regFree('gitTools.showOutput', () => output.show(true));

  reg('gitTools.push', (m) => cmd.push(m));
  reg('gitTools.update', (m) => cmd.update(m, context));
  reg('gitTools.fetch', (m) => cmd.fetch(m));
  reg('gitTools.branches', (m) => cmd.branchesPopup(m));
  reg('gitTools.newBranch', (m) => cmd.newBranch(m));
  reg('gitTools.checkoutRevision', (m) => cmd.checkoutRevision(m));
  reg('gitTools.stash', (m) => cmd.stash(m));
  reg('gitTools.manageRemotes', (m) => cmd.manageRemotes(m));
  reg('gitTools.resolveConflicts', (m) => cmd.resolveConflicts(m, (model, change) => openMergeTool(context, model, change)));
  reg('gitTools.continueOperation', (m) => {
    if (m.status.state === 'normal') return vscode.window.showInformationMessage('No merge, rebase, cherry-pick or revert in progress.');
    return m.run(`Continue ${m.status.state}`, () => m.repo.continueOperation(m.status.state));
  });
  reg('gitTools.abortOperation', async (m) => {
    if (m.status.state === 'normal') return vscode.window.showInformationMessage('No merge, rebase, cherry-pick or revert in progress.');
    const ok = await vscode.window.showWarningMessage(`Abort ${m.status.state}?`, { modal: true }, 'Abort');
    if (ok) await m.run(`Abort ${m.status.state}`, () => m.repo.abortOperation(m.status.state));
  });
  reg('gitTools.fileHistory', async (m, uri) => {
    const target = uri instanceof vscode.Uri ? uri : vscode.window.activeTextEditor?.document.uri;
    if (!target || target.scheme !== 'file') return vscode.window.showInformationMessage('Open a file to show its history.');
    const rel = path.relative(m.root, target.fsPath).replace(/\\/g, '/');
    if (rel.startsWith('..')) return vscode.window.showInformationMessage('The file is not in the current repository.');
    m.setLogFilter({ path: rel, branch: null });
    await vscode.commands.executeCommand('gitTools.log.focus');
  });

  // Branch / tag / stash items of the Branches tree (argument: tree node).
  const branchOf = (node) => (node && node.branch) || null;
  const branchCmd = (id, action) => reg(id, (m, node) => {
    const b = branchOf(node);
    if (b) return cmd.runBranchAction(m, b, action);
  });
  branchCmd('gitTools.branch.checkout', 'checkout');
  branchCmd('gitTools.branch.newFrom', 'new');
  branchCmd('gitTools.branch.checkoutRebase', 'checkoutRebase');
  branchCmd('gitTools.branch.compare', 'compare');
  branchCmd('gitTools.branch.rebaseOnto', 'rebase');
  branchCmd('gitTools.branch.merge', 'merge');
  branchCmd('gitTools.branch.update', 'update');
  branchCmd('gitTools.branch.push', 'push');
  branchCmd('gitTools.branch.rename', 'rename');
  branchCmd('gitTools.branch.delete', 'delete');
  branchCmd('gitTools.branch.copyName', 'copy');
  reg('gitTools.branch.showLog', (m, node) => {
    const b = branchOf(node);
    m.setLogFilter({ branch: b ? b.name : null, path: null });
    return vscode.commands.executeCommand('gitTools.log.focus');
  });
  reg('gitTools.tag.checkout', (m, node) => node && node.tag &&
    cmd.smartCheckout(m, `Checkout ${node.tag.name}`, () => m.repo.git.run(['checkout', `refs/tags/${node.tag.name}`], { log: true })));
  reg('gitTools.tag.push', async (m, node) => {
    if (!node || !node.tag) return;
    const remote = m.defaultRemote();
    if (!remote) return vscode.window.showWarningMessage('No remotes configured.');
    await m.run(`Push tag ${node.tag.name}`, () => m.repo.git.run(['push', '--progress', remote, `refs/tags/${node.tag.name}`], { log: true }),
      { success: `Pushed tag ${node.tag.name}` });
  });
  reg('gitTools.tag.delete', async (m, node) => {
    if (!node || !node.tag) return;
    const ok = await vscode.window.showWarningMessage(`Delete tag ${node.tag.name} locally?`, { modal: true }, 'Delete');
    if (ok) await m.run('Delete tag', () => m.repo.git.run(['tag', '-d', node.tag.name], { log: true }));
  });
  reg('gitTools.stash.apply', (m, node) => node && node.stash && cmd.stashApply(m, node.stash, false));
  reg('gitTools.stash.pop', (m, node) => node && node.stash && cmd.stashApply(m, node.stash, true));
  reg('gitTools.stash.drop', (m, node) => node && node.stash && cmd.stashDrop(m, node.stash));
  reg('gitTools.stash.branch', (m, node) => node && node.stash && cmd.stashBranch(m, node.stash));
  reg('gitTools.stash.showFiles', (m, node) => node && node.stash && cmd.stashShowFiles(m, node.stash));

  // AI commit messages.
  regFree('gitTools.ai.generate', (arg) => {
    // From the built-in Source Control title bar the argument is a SourceControl.
    const fromScm = arg && arg.rootUri instanceof vscode.Uri;
    if (fromScm) manager.open(arg.rootUri.fsPath).then(() => ai.generate({ toScm: true }));
    else ai.generate();
  });
  regFree('gitTools.ai.configure', () => ai.configure());
  regFree('gitTools.ai.setApiKey', () => ai.setApiKey());
  regFree('gitTools.ai.clearApiKey', () => ai.clearApiKey());
  regFree('gitTools.ai.testConnection', () => ai.testConnection());
  regFree('gitTools.ai.setupGuide', () => {
    const p = ai.provider();
    showSetupGuide(context, p === 'none' ? undefined : p);
  });

  await manager.discover();
}

function deactivate() {}

module.exports = { activate, deactivate };
