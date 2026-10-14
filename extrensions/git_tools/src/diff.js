// @ts-check
'use strict';

const vscode = require('vscode');
const path = require('path');

const SCHEME = 'gittools-rev';
const EMPTY = '__empty__';

/**
 * Serves file contents at a revision: gittools-rev:/path?{root, rev}.
 */
class RevisionContentProvider {
  /** @param {import('./model').RepoManager} manager */
  constructor(manager) {
    this.manager = manager;
  }

  /** @param {vscode.Uri} uri */
  async provideTextDocumentContent(uri) {
    const q = JSON.parse(uri.query);
    if (q.rev === EMPTY) return '';
    const model = this.manager.get(q.root);
    if (!model) return '';
    const bytes = await model.repo.show(q.rev, q.path);
    if (!bytes) return '';
    if (bytes.subarray(0, 8000).includes(0)) return `(binary file, ${bytes.length} bytes)`;
    return bytes.toString('utf8');
  }
}

/**
 * @param {string} root
 * @param {string} rev revision, '' for the index, EMPTY for nothing
 * @param {string} filePath repository relative path
 */
function revUri(root, rev, filePath) {
  const label = rev === EMPTY ? '(none)' : rev === '' ? 'index' : rev.length === 40 ? rev.slice(0, 8) : rev;
  return vscode.Uri.from({
    scheme: SCHEME,
    // The path drives the editor title and language detection.
    path: `/${filePath} (${label})`.replace(/\\/g, '/'),
    query: JSON.stringify({ root, rev, path: filePath }),
  });
}

function fileUri(root, filePath) {
  return vscode.Uri.file(path.join(root, filePath));
}

/**
 * Diff of a working tree change against HEAD.
 * @param {import('./model').RepoModel} model
 * @param {import('./git').FileChange} c
 */
async function openLocalDiff(model, c, preview = true) {
  const root = model.root;
  const hasHead = !!model.status.head;
  const name = path.basename(c.path);
  const left = c.type === 'untracked' || c.type === 'added' || !hasHead
    ? revUri(root, EMPTY, c.oldPath || c.path)
    : revUri(root, 'HEAD', c.oldPath || c.path);
  const right = c.type === 'deleted' ? revUri(root, EMPTY, c.path) : fileUri(root, c.path);
  await vscode.commands.executeCommand('vscode.diff', left, right, `${name} (HEAD ↔ Working Tree)`, { preview });
}

/**
 * Diff of a file changed in commit `hash` relative to `parent`.
 * @param {import('./model').RepoModel} model
 * @param {import('./git').FileChange} f
 * @param {string} hash
 * @param {string|null} parent
 */
async function openCommitDiff(model, f, hash, parent, preview = true) {
  const root = model.root;
  const name = path.basename(f.path);
  const left = !parent || f.type === 'added' || f.type === 'untracked'
    ? revUri(root, EMPTY, f.oldPath || f.path)
    : revUri(root, parent, f.oldPath || f.path);
  const right = f.type === 'deleted' ? revUri(root, EMPTY, f.path) : revUri(root, hash, f.path);
  const short = (r) => (/^[0-9a-f]{40}/.test(r) ? r.slice(0, 8) + r.slice(40) : r);
  const title = parent ? `${name} (${short(parent)} ↔ ${short(hash)})` : `${name} (${short(hash)})`;
  await vscode.commands.executeCommand('vscode.diff', left, right, title, { preview });
}

/** Compares a file at a revision with the working tree. */
async function openCompareWithLocal(model, filePath, rev) {
  const left = revUri(model.root, rev, filePath);
  const right = fileUri(model.root, filePath);
  const short = rev.length === 40 ? rev.slice(0, 8) : rev;
  await vscode.commands.executeCommand('vscode.diff', left, right, `${path.basename(filePath)} (${short} ↔ Working Tree)`);
}

module.exports = { SCHEME, EMPTY, RevisionContentProvider, revUri, fileUri, openLocalDiff, openCommitDiff, openCompareWithLocal };
