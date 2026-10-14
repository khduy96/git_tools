// @ts-check
'use strict';

const vscode = require('vscode');
const path = require('path');
const fs = require('fs');
const { GitError, lit } = require('./git');
const { openCommitDiff } = require('./diff');

/** @typedef {import('./model').RepoModel} RepoModel */
/** @typedef {import('./git').Branch} Branch */

const sep = (label) => ({ label, kind: vscode.QuickPickItemKind.Separator });

/** Simplified `git check-ref-format`. */
function validateRefName(name, existing = []) {
  const n = name.trim();
  if (!n) return 'Name cannot be empty';
  if (/[\s~^:?*[\\]/.test(n) || n.includes('..') || n.includes('@{') || n.startsWith('-') || n.startsWith('/') ||
      n.endsWith('/') || n.endsWith('.') || n.endsWith('.lock')) {
    return 'Invalid name';
  }
  if (existing.includes(n)) return `"${n}" already exists`;
  return null;
}

const currentLabel = (m) => m.status.branch || 'HEAD';

function warnConflicts(m) {
  const n = m.status.changes.filter((c) => c.type === 'conflicted').length;
  if (n) {
    vscode.window.showWarningMessage(`${n} file(s) have conflicts.`, 'Resolve…')
      .then((r) => { if (r) vscode.commands.executeCommand('gitTools.resolveConflicts'); });
  }
}

// ---------------------------------------------------------------- branches

/**
 * Checkout that offers Smart Checkout (stash, checkout, unstash) when local
 * changes would be overwritten.
 * @param {RepoModel} m
 */
async function smartCheckout(m, label, checkout) {
  m.busy = label;
  m.fire('busy');
  try {
    await checkout();
    vscode.window.setStatusBarMessage(`$(check) ${label}`, 4000);
  } catch (e) {
    m.busy = null;
    const overwritten = e instanceof GitError &&
      /would be overwritten|commit your changes or stash them/.test(e.stderr);
    if (!overwritten) {
      m.log(`${label} failed: ${e.message}`, 'error');
      vscode.window.showErrorMessage(`${label} failed: ${e.message}`);
      return;
    }
    const choice = await vscode.window.showWarningMessage(
      'Your local changes would be overwritten by checkout.',
      { modal: true, detail: `${e.message}\n\nSmart Checkout stashes local changes, checks out, then restores them.` },
      'Smart Checkout',
    );
    if (choice === 'Smart Checkout') {
      await m.run(label, async () => {
        await m.repo.git.run(['stash', 'push', '-m', 'Uncommitted changes before checkout'], { log: true });
        try {
          await checkout();
        } finally {
          await m.repo.git.run(['stash', 'pop'], { log: true });
        }
      }, { success: `${label} (local changes restored)` });
      return;
    }
  } finally {
    m.busy = null;
    m.fire('busy');
    await m.refreshAll();
  }
}

/** @param {RepoModel} m @param {Branch} b */
async function checkoutBranch(m, b) {
  if (b.current) return;
  if (!b.remote) {
    return smartCheckout(m, `Checkout ${b.name}`, () => m.repo.git.run(['checkout', b.name], { log: true }));
  }
  const short = b.name.slice(b.name.indexOf('/') + 1);
  const local = m.branches.find((x) => !x.remote && x.name === short);
  if (local) {
    return smartCheckout(m, `Checkout ${local.name}`, () => m.repo.git.run(['checkout', local.name], { log: true }));
  }
  return smartCheckout(m, `Checkout ${b.name}`,
    () => m.repo.git.run(['checkout', '-b', short, '--track', b.name], { log: true }));
}

/** @param {RepoModel} m */
async function newBranch(m, startPoint, startLabel) {
  const existing = m.branches.filter((b) => !b.remote).map((b) => b.name);
  const name = await vscode.window.showInputBox({
    title: startPoint ? `New Branch from ${startLabel || startPoint}` : 'Create New Branch',
    prompt: 'New branch name',
    validateInput: (v) => validateRefName(v, existing),
  });
  if (!name) return;
  const pick = await vscode.window.showQuickPick(
    [{ label: '$(check) Create and checkout', id: true }, { label: 'Create without checkout', id: false }],
    { title: `Create branch ${name.trim()}` },
  );
  if (!pick) return;
  const args = pick.id ? ['checkout', '-b', name.trim()] : ['branch', name.trim()];
  if (startPoint) args.push(startPoint);
  if (pick.id) await smartCheckout(m, `Create branch ${name.trim()}`, () => m.repo.git.run(args, { log: true }));
  else await m.run(`Create branch ${name.trim()}`, () => m.repo.git.run(args, { log: true }), { success: `Branch ${name.trim()} created` });
}

/** @param {RepoModel} m @param {Branch} b */
async function renameBranch(m, b) {
  const existing = m.branches.filter((x) => !x.remote).map((x) => x.name);
  const name = await vscode.window.showInputBox({
    title: `Rename Branch ${b.name}`,
    value: b.name,
    validateInput: (v) => (v.trim() === b.name ? 'Enter a different name' : validateRefName(v, existing)),
  });
  if (!name) return;
  await m.run('Rename branch', () => m.repo.git.run(['branch', '-m', b.name, name.trim()], { log: true }),
    { success: `Renamed to ${name.trim()}` });
}

/** @param {RepoModel} m @param {Branch} b */
async function deleteBranch(m, b) {
  if (b.remote) {
    const remote = b.name.slice(0, b.name.indexOf('/'));
    const branch = b.name.slice(b.name.indexOf('/') + 1);
    const ok = await vscode.window.showWarningMessage(`Delete remote branch ${b.name}?`,
      { modal: true, detail: `This pushes the deletion to ${remote}.` }, 'Delete');
    if (ok) {
      await m.run(`Delete ${b.name}`, () => m.repo.git.run(['push', '--progress', remote, '--delete', branch], { log: true }),
        { success: `Deleted ${b.name}` });
    }
    return;
  }
  const ok = await vscode.window.showWarningMessage(`Delete branch ${b.name}?`, { modal: true }, 'Delete');
  if (!ok) return;
  try {
    await m.repo.git.run(['branch', '-d', b.name], { log: true });
    vscode.window.setStatusBarMessage(`$(check) Deleted branch ${b.name}`, 4000);
  } catch (e) {
    if (e instanceof GitError && e.stderr.includes('not fully merged')) {
      const force = await vscode.window.showWarningMessage(`Branch ${b.name} is not fully merged.`,
        { modal: true, detail: 'Deleting it may lose commits. Delete anyway?' }, 'Force Delete');
      if (force) await m.run(`Delete ${b.name}`, () => m.repo.git.run(['branch', '-D', b.name], { log: true }));
    } else {
      vscode.window.showErrorMessage(`Delete branch failed: ${e.message}`);
    }
  }
  await m.refreshAll();
}

/** @param {RepoModel} m */
async function mergeIntoCurrent(m, ref) {
  await m.run(`Merge ${ref} into ${currentLabel(m)}`, () => m.repo.git.run(['merge', '--no-edit', ref], { log: true }),
    { success: `Merged ${ref}` });
  warnConflicts(m);
}

/** @param {RepoModel} m */
async function rebaseOnto(m, ref) {
  await m.run(`Rebase ${currentLabel(m)} onto ${ref}`, () => m.repo.git.run(['rebase', '--autostash', ref], { log: true }),
    { success: `Rebased onto ${ref}` });
  warnConflicts(m);
}

/** @param {RepoModel} m @param {Branch} b */
async function checkoutAndRebase(m, b) {
  const cur = currentLabel(m);
  await m.run(`Checkout ${b.name} and rebase onto ${cur}`,
    () => m.repo.git.run(['rebase', '--autostash', cur, b.name], { log: true }), { success: `Rebased ${b.name} onto ${cur}` });
  warnConflicts(m);
}

/** Lists commits on each side and lets the user open diffs of changed files. */
async function compareWithCurrent(m, ref) {
  const cur = currentLabel(m);
  const [theirs, ours, files] = await Promise.all([
    m.repo.commitsBetween('HEAD', ref),
    m.repo.commitsBetween(ref, 'HEAD'),
    m.repo.changedFiles('HEAD', ref),
  ]);
  const items = [
    sep(`Commits in ${ref} not in ${cur} (${theirs.length})`),
    ...theirs.map((c) => ({ label: `$(git-commit) ${c.subject}`, description: `${c.hash.slice(0, 8)} · ${c.author}` })),
    sep(`Commits in ${cur} not in ${ref} (${ours.length})`),
    ...ours.map((c) => ({ label: `$(git-commit) ${c.subject}`, description: `${c.hash.slice(0, 8)} · ${c.author}` })),
    sep(`Files that differ (${files.length}) — select to open diff`),
    ...files.map((f) => ({ label: `$(diff) ${path.basename(f.path)}`, description: f.path, file: f })),
  ];
  const qp = vscode.window.createQuickPick();
  qp.title = `Compare ${cur} with ${ref}`;
  qp.items = items;
  qp.matchOnDescription = true;
  qp.onDidAccept(() => {
    const sel = /** @type {any} */ (qp.selectedItems[0]);
    if (sel && sel.file) openCommitDiff(m, sel.file, ref, 'HEAD', false);
  });
  qp.onDidHide(() => qp.dispose());
  qp.show();
}

/** @param {RepoModel} m @param {Branch} b */
async function updateBranch(m, b) {
  if (!b.upstream) {
    vscode.window.showWarningMessage(`${b.name} has no upstream branch.`);
    return;
  }
  const slash = b.upstream.indexOf('/');
  await m.run(`Update ${b.name}`, () => m.repo.git.run(
    ['fetch', b.upstream.slice(0, slash), `${b.upstream.slice(slash + 1)}:${b.name}`], { log: true }),
  { success: `${b.name} updated` });
}

/** @param {RepoModel} m @param {Branch} b */
async function branchActions(m, b) {
  const cur = currentLabel(m);
  const q = (s) => `'${s.length > 32 ? `${s.slice(0, 30)}…` : s}'`;
  /** @type {{label: string, id: string}[]} */
  const items = [];
  if (!b.current) items.push({ label: '$(log-in) Checkout', id: 'checkout' });
  items.push({ label: `$(add) New Branch from ${q(b.name)}…`, id: 'new' });
  if (!b.current && !b.remote) items.push({ label: `$(git-pull-request) Checkout and Rebase onto ${q(cur)}`, id: 'checkoutRebase' });
  if (!b.current) items.push({ label: `$(compare-changes) Compare with ${q(cur)}`, id: 'compare' });
  items.push({ label: '$(history) Show in Log', id: 'log' });
  if (!b.current) {
    items.push({ label: `$(git-pull-request) Rebase ${q(cur)} onto ${q(b.name)}`, id: 'rebase' });
    items.push({ label: `$(git-merge) Merge ${q(b.name)} into ${q(cur)}`, id: 'merge' });
  }
  if (b.current) items.push({ label: '$(arrow-up) Push…', id: 'push' });
  if (!b.current && !b.remote && b.upstream) items.push({ label: `$(arrow-down) Update from ${b.upstream}`, id: 'update' });
  if (!b.remote) items.push({ label: '$(edit) Rename…', id: 'rename' });
  items.push({ label: '$(copy) Copy Branch Name', id: 'copy' });
  if (!b.current) items.push({ label: '$(trash) Delete', id: 'delete' });
  const pick = await vscode.window.showQuickPick(items, { title: b.name });
  if (!pick) return;
  return runBranchAction(m, b, pick.id);
}

/** @param {RepoModel} m @param {Branch} b */
async function runBranchAction(m, b, id) {
  switch (id) {
    case 'checkout': return checkoutBranch(m, b);
    case 'new': return newBranch(m, b.name);
    case 'checkoutRebase': return checkoutAndRebase(m, b);
    case 'compare': return compareWithCurrent(m, b.name);
    case 'log':
      m.setLogFilter({ branch: b.name, path: null });
      return vscode.commands.executeCommand('gitTools.log.focus');
    case 'rebase': return rebaseOnto(m, b.name);
    case 'merge': return mergeIntoCurrent(m, b.name);
    case 'push': return push(m);
    case 'update': return updateBranch(m, b);
    case 'rename': return renameBranch(m, b);
    case 'copy':
      await vscode.env.clipboard.writeText(b.name);
      return vscode.window.setStatusBarMessage(`Copied ${b.name}`, 3000);
    case 'delete': return deleteBranch(m, b);
  }
}

/** Android Studio style branches popup. @param {RepoModel} m */
async function branchesPopup(m) {
  const qp = vscode.window.createQuickPick();
  qp.title = `Git Branches · ${m.name}`;
  qp.placeholder = 'Search for branches and actions';
  qp.matchOnDescription = true;
  const sorted = (list) => [...list].sort((a, b) =>
    (b.current - a.current) || (fav(b) - fav(a)) || a.name.localeCompare(b.name));
  const fav = (b) => (/(^|\/)(main|master|develop)$/.test(b.name) ? 1 : 0);
  const branchItem = (b) => ({
    label: `${b.current ? '$(tag)' : fav(b) ? '$(star-full)' : '$(git-branch)'} ${b.name}`,
    description: [b.ahead ? `↑${b.ahead}` : '', b.behind ? `↓${b.behind}` : '', b.upstream && !b.remote ? b.upstream : '']
      .filter(Boolean).join(' '),
    branch: b,
  });
  qp.items = [
    { label: '$(arrow-down) Update Project…', id: 'update' },
    { label: '$(check) Commit…', id: 'commit' },
    { label: '$(arrow-up) Push…', id: 'push' },
    sep(''),
    { label: '$(add) New Branch…', id: 'new' },
    { label: '$(tag) Checkout Tag or Revision…', id: 'revision' },
    sep('Local'),
    ...sorted(m.branches.filter((b) => !b.remote)).map(branchItem),
    sep('Remote'),
    ...sorted(m.branches.filter((b) => b.remote)).map(branchItem),
  ];
  qp.onDidAccept(async () => {
    const sel = /** @type {any} */ (qp.selectedItems[0]);
    qp.hide();
    if (!sel) return;
    if (sel.branch) return branchActions(m, sel.branch);
    switch (sel.id) {
      case 'update': return update(m);
      case 'commit': return vscode.commands.executeCommand('gitTools.focusCommit');
      case 'push': return push(m);
      case 'new': return newBranch(m);
      case 'revision': return checkoutRevision(m);
    }
  });
  qp.onDidHide(() => qp.dispose());
  qp.show();
}

/** @param {RepoModel} m */
async function checkoutRevision(m) {
  const items = [
    ...m.tags.map((t) => ({ label: `$(tag) ${t.name}`, ref: `refs/tags/${t.name}` })),
  ];
  const qp = vscode.window.createQuickPick();
  qp.title = 'Checkout Tag or Revision';
  qp.placeholder = 'Type a tag, branch or commit hash';
  qp.items = items;
  const ref = await new Promise((resolve) => {
    qp.onDidAccept(() => {
      const sel = /** @type {any} */ (qp.selectedItems[0]);
      resolve(sel ? sel.ref : qp.value.trim());
      qp.hide();
    });
    qp.onDidHide(() => resolve(null));
    qp.show();
  });
  qp.dispose();
  if (!ref) return;
  if (!(await m.repo.refExists(`${ref}^{commit}`))) {
    vscode.window.showErrorMessage(`Unknown revision: ${ref}`);
    return;
  }
  await smartCheckout(m, `Checkout ${ref}`, () => m.repo.git.run(['checkout', ref], { log: true }));
}

// ---------------------------------------------------------------- remote

/** Push dialog: shows outgoing commits, target branch, force option. @param {RepoModel} m */
async function push(m) {
  const branch = m.status.branch;
  if (!branch) {
    vscode.window.showWarningMessage('Cannot push from a detached HEAD. Checkout a branch first.');
    return;
  }
  if (!m.remotes.length) {
    vscode.window.showWarningMessage('No remotes configured.', 'Manage Remotes…')
      .then((r) => { if (r) manageRemotes(m); });
    return;
  }
  let remote = m.defaultRemote();
  const up = m.status.upstream;
  let target = up && up.startsWith(`${remote}/`) ? up.slice(remote.length + 1) : branch;

  for (;;) {
    const remoteRef = `refs/remotes/${remote}/${target}`;
    const exists = await m.repo.refExists(remoteRef);
    const commits = await m.repo.outgoing('HEAD', remote, exists ? remoteRef : null);
    const dest = `${remote}/${target}${exists ? '' : ' (new)'}`;
    const items = [
      { label: `$(arrow-up) Push ${commits.length} commit(s) to ${dest}`, id: 'push' },
      { label: '$(warning) Force Push (--force-with-lease)', id: 'force', description: 'overwrites remote history if unchanged since last fetch' },
      { label: '$(tag) Push with tags', id: 'tags' },
      { label: '$(edit) Change remote or target branch…', id: 'target' },
      sep(commits.length ? 'Commits to push' : 'Nothing to push'),
      ...commits.map((c) => ({ label: `$(git-commit) ${c.subject}`, description: `${c.hash.slice(0, 8)} · ${c.author}`, commit: c })),
    ];
    const pick = /** @type {any} */ (await vscode.window.showQuickPick(items, { title: `Push ${branch} → ${dest}` }));
    if (!pick) return;
    if (pick.commit) continue;
    if (pick.id === 'target') {
      const r = m.remotes.length > 1
        ? await vscode.window.showQuickPick(m.remotes.map((x) => ({ label: x.name, description: x.url })), { title: 'Remote' })
        : { label: remote };
      if (!r) continue;
      const t = await vscode.window.showInputBox({ title: 'Target branch on remote', value: target, validateInput: (v) => validateRefName(v) });
      if (!t) continue;
      remote = r.label;
      target = t.trim();
      continue;
    }
    if (pick.id === 'force') {
      const ok = await vscode.window.showWarningMessage(`Force push ${branch} to ${remote}/${target}?`, { modal: true }, 'Force Push');
      if (!ok) continue;
    }
    const args = ['push', '--progress'];
    if (pick.id === 'force') args.push('--force-with-lease');
    if (pick.id === 'tags') args.push('--follow-tags');
    if (!m.status.upstream) args.push('--set-upstream');
    args.push(remote, `refs/heads/${branch}:refs/heads/${target}`);
    await m.run(pick.id === 'force' ? 'Force push' : 'Push', () => m.repo.git.run(args, { log: true }),
      { success: `Pushed to ${remote}/${target}` });
    return;
  }
}

/** Update Project / Pull. @param {RepoModel} m */
async function update(m, context) {
  if (!m.status.branch) {
    vscode.window.showWarningMessage('Cannot update a detached HEAD. Checkout a branch first.');
    return;
  }
  if (!m.remotes.length) {
    vscode.window.showWarningMessage('No remotes configured.');
    return;
  }
  let remote = m.defaultRemote();
  const up = m.status.upstream;
  let branch = up && up.startsWith(`${remote}/`) ? up.slice(remote.length + 1) : null;
  if (!branch) {
    const candidates = m.branches.filter((b) => b.remote);
    const pick = await vscode.window.showQuickPick(
      candidates.map((b) => ({ label: b.name })), { title: 'No upstream branch: choose the remote branch to pull' });
    if (!pick) return;
    remote = pick.label.slice(0, pick.label.indexOf('/'));
    branch = pick.label.slice(pick.label.indexOf('/') + 1);
  }
  const last = context ? context.globalState.get('gitTools.pullMode', 'merge') : 'merge';
  const modes = [
    { label: '$(git-merge) Merge', description: 'Merge incoming changes into the current branch', id: 'merge' },
    { label: '$(git-pull-request) Rebase', description: 'Rebase the current branch on top of incoming changes', id: 'rebase' },
    { label: '$(arrow-right) Fast-forward only', description: 'Fail if the update cannot be fast-forwarded', id: 'ff' },
  ].sort((a, b) => (b.id === last) - (a.id === last));
  const mode = /** @type {any} */ (await vscode.window.showQuickPick(modes, { title: `Update ${m.status.branch} from ${remote}/${branch}` }));
  if (!mode) return;
  if (context) context.globalState.update('gitTools.pullMode', mode.id);
  const args = ['pull', '--progress', '--no-edit'];
  if (mode.id === 'ff') args.push('--ff-only');
  else if (mode.id === 'rebase') args.push('--rebase', '--autostash');
  else args.push('--no-rebase');
  args.push(remote, branch);
  await m.run(`Update ${m.status.branch}`, () => m.repo.git.run(args, { log: true }), { success: `Updated from ${remote}/${branch}` });
  warnConflicts(m);
}

/** @param {RepoModel} m */
async function fetch(m) {
  await m.run('Fetch', () => m.repo.git.run(['fetch', '--progress', '--prune', '--all'], { log: true }), { success: 'Fetched all remotes' });
}

/** @param {RepoModel} m */
async function manageRemotes(m) {
  const pick = /** @type {any} */ (await vscode.window.showQuickPick([
    { label: '$(add) Add Remote…', id: 'add' },
    sep('Remotes'),
    ...m.remotes.map((r) => ({ label: `$(cloud) ${r.name}`, description: r.url, remote: r })),
  ], { title: 'Git Remotes' }));
  if (!pick) return;
  if (pick.id === 'add') {
    const name = await vscode.window.showInputBox({ title: 'Remote name', value: m.remotes.length ? '' : 'origin', validateInput: (v) => validateRefName(v, m.remotes.map((r) => r.name)) });
    if (!name) return;
    const url = await vscode.window.showInputBox({ title: `URL of ${name}`, placeHolder: 'https://github.com/user/repo.git' });
    if (!url) return;
    await m.run('Add remote', () => m.repo.git.run(['remote', 'add', name.trim(), url.trim()], { log: true }));
    return;
  }
  const action = await vscode.window.showQuickPick(['Edit URL…', 'Remove'], { title: pick.remote.name });
  if (action === 'Edit URL…') {
    const url = await vscode.window.showInputBox({ title: `URL of ${pick.remote.name}`, value: pick.remote.url });
    if (url) await m.run('Edit remote', () => m.repo.git.run(['remote', 'set-url', pick.remote.name, url.trim()], { log: true }));
  } else if (action === 'Remove') {
    const ok = await vscode.window.showWarningMessage(`Remove remote ${pick.remote.name}?`, { modal: true }, 'Remove');
    if (ok) await m.run('Remove remote', () => m.repo.git.run(['remote', 'remove', pick.remote.name], { log: true }));
  }
}

// ---------------------------------------------------------------- stash

/** @param {RepoModel} m */
async function stash(m) {
  if (!m.status.changes.length) {
    vscode.window.showInformationMessage('There are no local changes to stash.');
    return;
  }
  const message = await vscode.window.showInputBox({ title: 'Stash Changes', prompt: 'Message (optional)' });
  if (message === undefined) return;
  const opts = await vscode.window.showQuickPick([
    { label: 'Include unversioned files', picked: false, id: 'u' },
    { label: 'Keep index', picked: false, id: 'k' },
  ], { title: 'Stash options', canPickMany: true });
  if (!opts) return;
  const args = ['stash', 'push'];
  if (opts.some((o) => o.id === 'u')) args.push('--include-untracked');
  if (opts.some((o) => o.id === 'k')) args.push('--keep-index');
  if (message.trim()) args.push('-m', message.trim());
  await m.run('Stash changes', () => m.repo.git.run(args, { log: true }), { success: 'Local changes stashed' });
}

async function stashApply(m, s, pop) {
  await m.run(`${pop ? 'Pop' : 'Apply'} ${s.ref}`, () => m.repo.git.run(['stash', pop ? 'pop' : 'apply', s.ref], { log: true }),
    { success: pop ? 'Stash popped' : 'Stash applied' });
  warnConflicts(m);
}

async function stashDrop(m, s) {
  const ok = await vscode.window.showWarningMessage(`Drop ${s.ref} "${s.message}"?`, { modal: true }, 'Drop');
  if (ok) await m.run(`Drop ${s.ref}`, () => m.repo.git.run(['stash', 'drop', s.ref], { log: true }));
}

async function stashBranch(m, s) {
  const name = await vscode.window.showInputBox({
    title: 'Unstash as Branch', prompt: 'New branch name',
    validateInput: (v) => validateRefName(v, m.branches.filter((b) => !b.remote).map((b) => b.name)),
  });
  if (name) await m.run('Unstash as branch', () => m.repo.git.run(['stash', 'branch', name.trim(), s.ref], { log: true }));
}

async function stashShowFiles(m, s) {
  const files = await m.repo.stashFiles(s);
  const pick = /** @type {any} */ (await vscode.window.showQuickPick(
    files.map((f) => ({ label: `$(diff) ${path.basename(f.path)}`, description: `${f.type} · ${f.path}`, file: f })),
    { title: `${s.ref}: ${s.message}`, matchOnDescription: true }));
  if (!pick) return;
  const f = pick.file;
  if (f.type === 'untracked') await openCommitDiff(m, { ...f, type: 'added' }, `${s.hash}^3`, null, false);
  else await openCommitDiff(m, f, s.hash, `${s.hash}^1`, false);
}

// ---------------------------------------------------------------- conflicts

/** @param {RepoModel} m */
async function resolveConflicts(m, openMergeTool) {
  const conflicts = m.status.changes.filter((c) => c.type === 'conflicted');
  if (!conflicts.length) {
    vscode.window.showInformationMessage('No conflicts.');
    return;
  }
  const side = (ch) => ({ D: 'deleted', A: 'added' }[ch] || 'modified');
  const yours = m.status.state === 'rebasing' ? 'upstream' : 'yours';
  const theirs = m.status.state === 'rebasing' ? 'your commit' : 'theirs';
  const pick = /** @type {any} */ (await vscode.window.showQuickPick(conflicts.map((c) => {
    const code = c.conflictCode || 'UU';
    return { label: `$(warning) ${c.path}`, description: `${yours}: ${side(code[0])} · ${theirs}: ${side(code[1])}`, change: c };
  }), { title: `Conflicts (${conflicts.length})` }));
  if (!pick) return;
  const c = pick.change;
  const canMerge = !(c.conflictCode || '').includes('D');
  const action = /** @type {any} */ (await vscode.window.showQuickPick([
    ...(canMerge ? [{ label: '$(git-merge) Merge…', description: '3-way merge tool', id: 'merge' }] : []),
    { label: `$(arrow-left) Accept ${yours[0].toUpperCase()}${yours.slice(1)}`, id: 'ours' },
    { label: `$(arrow-right) Accept ${theirs[0].toUpperCase()}${theirs.slice(1)}`, id: 'theirs' },
    ...(canMerge ? [{ label: '$(go-to-file) Open in Editor', description: 'resolve markers manually, then Mark as Resolved', id: 'open' }] : []),
    { label: '$(check) Mark as Resolved', id: 'resolved' },
  ], { title: c.path }));
  if (!action) return;
  switch (action.id) {
    case 'merge': return openMergeTool(m, c);
    case 'ours':
    case 'theirs':
      return m.run(`Accept ${action.id}`, () => m.repo.acceptSide(c, action.id === 'ours'), { success: `${c.path} resolved` });
    case 'open':
      return vscode.window.showTextDocument(vscode.Uri.file(path.join(m.root, c.path)));
    case 'resolved': {
      const text = fs.existsSync(path.join(m.root, c.path)) ? fs.readFileSync(path.join(m.root, c.path), 'utf8') : '';
      if (/^<{7}( |$)/m.test(text)) {
        const ok = await vscode.window.showWarningMessage('The file still contains conflict markers. Mark as resolved anyway?', { modal: true }, 'Mark Resolved');
        if (!ok) return;
      }
      return m.run('Mark resolved', () => m.repo.markResolved(c.path), { success: `${c.path} resolved` });
    }
  }
}

// ---------------------------------------------------------------- commits

const RESET_MODES = [
  { label: 'Soft', id: 'soft', detail: 'Files won\'t change, differences will be staged for commit.' },
  { label: 'Mixed', id: 'mixed', detail: 'Files won\'t change, differences won\'t be staged.' },
  { label: 'Hard', id: 'hard', detail: 'Files will be reverted to the selected commit. Local changes will be lost!' },
  { label: 'Keep', id: 'keep', detail: 'Files will be reverted to the selected commit, local changes are kept.' },
];

/** Handles an action chosen in the Log context menu. @param {RepoModel} m */
async function commitAction(m, action, commits) {
  const c = commits[0];
  const short = c.hash.slice(0, 8);
  switch (action) {
    case 'copy':
      await vscode.env.clipboard.writeText(commits.map((x) => x.hash).join(' '));
      return vscode.window.setStatusBarMessage('Revision number copied', 3000);
    case 'cherryPick':
      await m.run(commits.length > 1 ? `Cherry-pick ${commits.length} commits` : `Cherry-pick ${short}`, async () => {
        for (const x of [...commits].reverse()) {
          await m.repo.git.run(['cherry-pick', ...(x.parents.length > 1 ? ['-m', '1'] : []), x.hash], { log: true });
        }
      }, { success: 'Cherry-picked' });
      return warnConflicts(m);
    case 'checkout':
      return smartCheckout(m, `Checkout ${short}`, () => m.repo.git.run(['checkout', c.hash], { log: true }));
    case 'compare':
      return compareWithCurrent(m, c.hash);
    case 'reset': {
      const mode = /** @type {any} */ (await vscode.window.showQuickPick(RESET_MODES, {
        title: `Reset ${currentLabel(m)} to ${short}`, placeHolder: 'Choose how the working tree and index are changed',
      }));
      if (!mode) return;
      if (mode.id === 'hard') {
        const ok = await vscode.window.showWarningMessage(`Hard reset ${currentLabel(m)} to ${short}?`, { modal: true, detail: 'All local changes will be lost.' }, 'Reset');
        if (!ok) return;
      }
      return m.run(`Reset to ${short}`, () => m.repo.git.run(['reset', `--${mode.id}`, c.hash], { log: true }), { success: `Reset to ${short} (${mode.id})` });
    }
    case 'revert':
      await m.run(commits.length > 1 ? `Revert ${commits.length} commits` : `Revert ${short}`, async () => {
        for (const x of commits) {
          await m.repo.git.run(['revert', '--no-edit', ...(x.parents.length > 1 ? ['-m', '1'] : []), x.hash], { log: true });
        }
      }, { success: 'Reverted' });
      return warnConflicts(m);
    case 'undo': {
      const ok = await vscode.window.showWarningMessage('Undo the last commit?', { modal: true, detail: 'Its changes are kept in the working tree.' }, 'Undo Commit');
      if (ok) await m.run('Undo commit', () => m.repo.git.run(['reset', '--soft', 'HEAD~1'], { log: true }), { success: 'Commit undone' });
      return;
    }
    case 'reword': {
      const current = await m.repo.lastCommitMessage();
      const msg = await vscode.window.showInputBox({ title: 'Edit Commit Message', value: current, validateInput: (v) => (v.trim() ? null : 'Message cannot be empty') });
      if (!msg || msg.trim() === current) return;
      return m.run('Edit commit message', () => m.repo.commit({ message: msg.trim(), paths: [], amend: true }), { success: 'Commit message updated' });
    }
    case 'drop': {
      const ok = await vscode.window.showWarningMessage(`Drop commit ${short} "${c.subject}"?`, { modal: true, detail: 'This rewrites the history of the current branch.' }, 'Drop');
      if (ok) await m.run('Drop commit', () => m.repo.git.run(['rebase', '--autostash', '--onto', `${c.hash}^`, c.hash], { log: true }), { success: `Dropped ${short}` });
      return;
    }
    case 'branch':
      return newBranch(m, c.hash, short);
    case 'tag': {
      const name = await vscode.window.showInputBox({ title: `Tag commit ${short}`, prompt: 'Tag name', validateInput: (v) => validateRefName(v, m.tags.map((t) => t.name)) });
      if (!name) return;
      const message = await vscode.window.showInputBox({ title: `Tag ${name}`, prompt: 'Message (optional, creates an annotated tag)' });
      if (message === undefined) return;
      const args = ['tag', ...(message.trim() ? ['-a', '-m', message.trim()] : []), name.trim(), c.hash];
      return m.run(`Create tag ${name}`, () => m.repo.git.run(args, { log: true }), { success: `Tag ${name} created` });
    }
  }
}

/** Rollback dialog for working tree changes. @param {RepoModel} m */
async function rollback(m, changes) {
  const tracked = changes.filter((c) => c.type !== 'untracked' && c.type !== 'conflicted');
  if (!tracked.length) return;
  const picks = await vscode.window.showQuickPick(
    tracked.map((c) => ({ label: path.basename(c.path), description: `${c.type} · ${c.path}`, picked: true, change: c })),
    { title: 'Rollback Changes', canPickMany: true, placeHolder: 'Selected files are reverted to HEAD' });
  if (!picks || !picks.length) return;
  const sel = picks.map((p) => p.change);
  let deleteAdded = false;
  if (sel.some((c) => c.type === 'added')) {
    const r = await vscode.window.showQuickPick(['Keep local copies of added files', 'Delete local copies of added files'], { title: 'Added files' });
    if (!r) return;
    deleteAdded = r.startsWith('Delete');
  }
  await m.run('Rollback', () => m.repo.rollback(sel, !!m.status.head, deleteAdded), { success: `${sel.length} file(s) rolled back` });
}

/** @param {RepoModel} m */
async function deleteUntracked(m, changes) {
  const ok = await vscode.window.showWarningMessage(
    changes.length === 1 ? `Delete ${changes[0].path}?` : `Delete ${changes.length} unversioned files?`, { modal: true }, 'Delete');
  if (!ok) return;
  for (const c of changes) fs.rmSync(path.join(m.root, c.path), { force: true });
  await m.refreshStatus();
}

/**
 * Starts tracking unversioned files (Android Studio "Add to VCS"): they move
 * from "Unversioned Files" to "Changes" and are included in the next commit.
 * @param {RepoModel} m
 */
async function addToVcs(m, changes) {
  const files = changes.filter((c) => c.type === 'untracked');
  if (!files.length) return;
  for (const c of files) m.excludedTracked.delete(c.path);
  await m.run(files.length === 1 ? `Add ${path.basename(files[0].path)} to Git` : `Add ${files.length} files to Git`,
    // Paths go through stdin: a dragged folder can contain thousands of files.
    () => m.repo.git.run(['add', '--pathspec-from-file=-', '--pathspec-file-nul'],
      { stdin: `${files.map((c) => lit(c.path)).join('\0')}\0`, log: true }),
    { success: `${files.length} file(s) added to Git`, refresh: false });
  await m.refreshStatus();
}

/**
 * Stops tracking newly added files without deleting them: they move back to
 * "Unversioned Files".
 * @param {RepoModel} m
 */
async function unversion(m, changes) {
  const files = changes.filter((c) => c.type === 'added');
  if (!files.length) return;
  await m.run(files.length === 1 ? `Unversion ${path.basename(files[0].path)}` : `Unversion ${files.length} files`,
    () => m.repo.git.run(['rm', '--cached', '-q', '--pathspec-from-file=-', '--pathspec-file-nul'],
      { stdin: `${files.map((c) => lit(c.path)).join('\0')}\0`, log: true }),
    { success: `${files.length} file(s) moved to Unversioned Files`, refresh: false });
  await m.refreshStatus();
}

/** @param {RepoModel} m */
async function addToGitignore(m, changes) {
  const file = path.join(m.root, '.gitignore');
  let content = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';
  if (content && !content.endsWith('\n')) content += '\n';
  content += changes.map((c) => `/${c.path}`).join('\n') + '\n';
  fs.writeFileSync(file, content);
  await m.refreshStatus();
}

module.exports = {
  validateRefName, smartCheckout, checkoutBranch, newBranch, renameBranch, deleteBranch, mergeIntoCurrent, rebaseOnto,
  checkoutAndRebase, compareWithCurrent, updateBranch, branchActions, runBranchAction, branchesPopup, checkoutRevision,
  push, update, fetch, manageRemotes, stash, stashApply, stashDrop, stashBranch, stashShowFiles, resolveConflicts,
  commitAction, rollback, deleteUntracked, addToGitignore, addToVcs, unversion, lit,
};
