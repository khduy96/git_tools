// @ts-check
'use strict';

const vscode = require('vscode');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { webviewHtml } = require('./webview');
const { hasConflictMarkers, parseConflicts, joinSegments } = require('./conflicts');

/** Re-creates conflicted content from the index stages. */
async function mergeFromStages(m, filePath) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'git_tools_merge'));
  try {
    const stage = async (n) => (await m.repo.show(`:${n}`, filePath)) || Buffer.alloc(0);
    const files = { ours: await stage(2), base: await stage(1), theirs: await stage(3) };
    for (const [k, v] of Object.entries(files)) fs.writeFileSync(path.join(tmp, k), v);
    const r = await m.repo.git.raw(['merge-file', '-p', '--diff3', '-L', 'ours', '-L', 'base', '-L', 'theirs',
      path.join(tmp, 'ours'), path.join(tmp, 'base'), path.join(tmp, 'theirs')]);
    return r.stdout;
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

/**
 * Opens the three-way merge tool for a conflicted file.
 * @param {vscode.ExtensionContext} context
 * @param {import('./model').RepoModel} m
 * @param {import('./git').FileChange} change
 */
async function openMergeTool(context, m, change) {
  const full = path.join(m.root, change.path);
  let text = fs.existsSync(full) ? fs.readFileSync(full, 'utf8') : '';
  if (!hasConflictMarkers(text)) text = await mergeFromStages(m, change.path);
  const eol = text.includes('\r\n') ? '\r\n' : '\n';
  const segments = parseConflicts(text);
  if (!segments.some((s) => s.kind === 'conflict')) {
    const ok = await vscode.window.showInformationMessage(`${change.path} has no conflict markers. Mark it as resolved?`, 'Mark Resolved');
    if (ok) await m.run('Mark resolved', () => m.repo.markResolved(change.path));
    return;
  }

  const rebasing = m.status.state === 'rebasing';
  const panel = vscode.window.createWebviewPanel('gitTools.merge', `Merge: ${path.basename(change.path)}`,
    vscode.ViewColumn.Active, {
      enableScripts: true,
      retainContextWhenHidden: true,
      localResourceRoots: [vscode.Uri.joinPath(context.extensionUri, 'media')],
    });
  panel.webview.html = webviewHtml(panel.webview, context.extensionUri, {
    title: 'Merge',
    styles: ['merge.css'],
    scripts: ['common.js', 'merge.js'],
  });
  panel.webview.onDidReceiveMessage(async (msg) => {
    if (msg.type === 'ready') {
      panel.webview.postMessage({
        type: 'init',
        path: change.path,
        segments,
        left: rebasing ? 'Upstream (rebasing onto)' : `Yours (${m.status.branch || 'HEAD'})`,
        right: rebasing ? 'Your commit' : 'Theirs (incoming)',
      });
    } else if (msg.type === 'apply') {
      const content = joinSegments(segments, msg.resolutions, eol);
      fs.writeFileSync(full, content, 'utf8');
      panel.dispose();
      await m.run(`Resolve ${path.basename(change.path)}`, () => m.repo.markResolved(change.path), { success: `${change.path} resolved` });
      if (!m.status.changes.some((c) => c.type === 'conflicted')) {
        vscode.window.showInformationMessage('All conflicts resolved.', 'Continue').then((r) => {
          if (r) vscode.commands.executeCommand('gitTools.continueOperation');
        });
      }
    } else if (msg.type === 'cancel') {
      panel.dispose();
    }
  });
}

module.exports = { openMergeTool, mergeFromStages };
