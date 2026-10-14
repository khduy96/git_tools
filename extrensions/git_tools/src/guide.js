// @ts-check
'use strict';

const vscode = require('vscode');
const { webviewHtml } = require('./webview');

/** @type {vscode.WebviewPanel|null} */
let panel = null;

/**
 * Opens (or focuses) the AI setup guide.
 * @param {vscode.ExtensionContext} context
 * @param {'gemini'|'claude'|'usage'} [tab]
 */
function showSetupGuide(context, tab) {
  if (panel) {
    panel.reveal();
    if (tab) panel.webview.postMessage({ type: 'tab', tab });
    return;
  }
  panel = vscode.window.createWebviewPanel('gitTools.guide', 'AI Commit Message Setup', vscode.ViewColumn.Active, {
    enableScripts: true,
    localResourceRoots: [vscode.Uri.joinPath(context.extensionUri, 'media')],
  });
  panel.webview.html = webviewHtml(panel.webview, context.extensionUri, {
    title: 'Setup Guide',
    styles: ['guide.css'],
    scripts: ['common.js', 'guide.js'],
  });
  panel.webview.onDidReceiveMessage(async (msg) => {
    switch (msg.type) {
      case 'ready':
        if (tab) panel?.webview.postMessage({ type: 'tab', tab });
        return;
      case 'openUrl':
        if (/^https:\/\//.test(msg.url)) vscode.env.openExternal(vscode.Uri.parse(msg.url));
        return;
      case 'command':
        if (String(msg.command).startsWith('gitTools.ai.')) vscode.commands.executeCommand(msg.command);
        return;
      case 'settings':
        vscode.commands.executeCommand('workbench.action.openSettings', 'gitTools.ai');
        return;
      case 'copy':
        await vscode.env.clipboard.writeText(msg.text);
        vscode.window.setStatusBarMessage(`Copied ${msg.text}`, 3000);
    }
  });
  panel.onDidDispose(() => { panel = null; });
}

module.exports = { showSetupGuide };
