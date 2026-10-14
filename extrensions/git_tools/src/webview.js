// @ts-check
'use strict';

const vscode = require('vscode');
const crypto = require('crypto');

/**
 * Builds the HTML shell of a webview with a strict CSP.
 * @param {vscode.Webview} webview
 * @param {vscode.Uri} extensionUri
 * @param {{scripts: string[], styles: string[], body?: string, title?: string}} o
 */
function webviewHtml(webview, extensionUri, o) {
  const nonce = crypto.randomBytes(16).toString('base64');
  const uri = (p) => webview.asWebviewUri(vscode.Uri.joinPath(extensionUri, 'media', p));
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src ${webview.cspSource} data:; style-src ${webview.cspSource} 'unsafe-inline'; font-src ${webview.cspSource}; script-src 'nonce-${nonce}';">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>${o.title || 'Git Tools'}</title>
<link rel="stylesheet" href="${uri('common.css')}">
${o.styles.map((s) => `<link rel="stylesheet" href="${uri(s)}">`).join('\n')}
</head>
<body>
${o.body || '<div id="app"></div>'}
${o.scripts.map((s) => `<script nonce="${nonce}" src="${uri(s)}"></script>`).join('\n')}
</body>
</html>`;
}

module.exports = { webviewHtml };
