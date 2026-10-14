// @ts-check
'use strict';

const vscode = require('vscode');
const { createAi, AiError } = require('./ai');

const SECRET = { claude: 'gitTools.ai.claudeApiKey', gemini: 'gitTools.ai.geminiApiKey' };
const PROVIDER_NAME = { claude: 'Anthropic Claude', gemini: 'Google Gemini' };
const MODEL_SETTING = { claude: 'ai.claudeModel', gemini: 'ai.geminiModel' };
const SUGGESTIONS = {
  claude: [
    { label: 'claude-opus-5-5', description: 'highest quality' },
    { label: 'claude-sonnet-5-5', description: 'balance of cost and quality' },
    { label: 'claude-haiku-5-5', description: 'cheapest and fastest' },
  ],
  gemini: [
    { label: 'gemini-3.5-flash-lite', description: 'fast, usually a larger free daily quota' },
    { label: 'gemini-3.8-flash', description: 'better messages, smaller free quota' },
    { label: 'gemini-2.5-flash-lite', description: 'previous generation' },
  ],
};
const MAX_FILE_DIFF = 40000;
const MAX_TOTAL_DIFF = 150000;

/**
 * AI commit message generation. Nothing is configured by default; keys live
 * in VS Code Secret Storage.
 */
class AiController {
  /**
   * @param {vscode.ExtensionContext} context
   * @param {import('./model').RepoManager} manager
   */
  constructor(context, manager) {
    this.context = context;
    this.manager = manager;
    this.generating = false;
    /** @type {import('./ai').ClaudeCommitAi|import('./ai').GeminiCommitAi|null} */
    this.ai = null;
    /** @type {Record<string, boolean>} */
    this.hasKey = { claude: false, gemini: false };
    this._onDidChange = new vscode.EventEmitter();
    this.onDidChange = this._onDidChange.event;
    context.subscriptions.push(
      this._onDidChange,
      context.secrets.onDidChange(() => this.loadKeys()),
      vscode.workspace.onDidChangeConfiguration((e) => {
        if (e.affectsConfiguration('gitTools.ai')) this._onDidChange.fire(undefined);
      }),
    );
    this.loadKeys();
  }

  async loadKeys() {
    for (const p of ['claude', 'gemini']) this.hasKey[p] = !!(await this.context.secrets.get(SECRET[p]));
    this._onDidChange.fire(undefined);
  }

  get cfg() {
    return vscode.workspace.getConfiguration('gitTools');
  }

  /** @returns {'none'|'claude'|'gemini'} */
  provider() {
    return /** @type {any} */ (this.cfg.get('ai.provider') || 'none');
  }

  model() {
    const p = this.provider();
    return p === 'none' ? '' : String(this.cfg.get(MODEL_SETTING[p]) || '').trim();
  }

  isConfigured() {
    const p = this.provider();
    return p !== 'none' && !!this.model() && this.hasKey[p];
  }

  setGenerating(v) {
    this.generating = v;
    this._onDidChange.fire(undefined);
  }

  cancel() {
    if (this.ai) this.ai.cancel();
  }

  async notConfigured() {
    const r = await vscode.window.showInformationMessage(
      'AI commit messages are not set up yet. Choose a provider and enter your own API key.',
      'Configure…', 'Setup Guide');
    if (r === 'Configure…') await this.configure();
    else if (r === 'Setup Guide') vscode.commands.executeCommand('gitTools.ai.setupGuide');
  }

  /**
   * Generates a message for the checked changes of the current repository.
   * @param {{toScm?: any}} [o] when set, writes into the built-in Git input box
   */
  async generate(o = {}) {
    const m = this.manager.current;
    if (!m) {
      vscode.window.showWarningMessage('No Git repository is open.');
      return;
    }
    if (!this.isConfigured()) return this.notConfigured();
    if (this.generating) return;

    const s = m.status;
    const changes = m.includedChanges();
    const amend = m.amend && !!s.head;
    if (!changes.length && !amend) {
      vscode.window.showWarningMessage('Check the files to commit first: the message is generated from the checked changes.');
      return;
    }
    const p = this.provider();
    const apiKey = await this.context.secrets.get(SECRET[p]);
    if (!apiKey) return this.notConfigured();

    const previous = m.message;
    const scmInput = o.toScm ? scmInputBox(m.root) : null;
    const write = (text) => {
      if (scmInput) scmInput.value = text;
      else {
        m.message = text;
        m.fire('message');
      }
    };

    this.setGenerating(true);
    try {
      let base = s.head ? 'HEAD' : null;
      let files = [...changes];
      let amendOf = null;
      if (amend) {
        amendOf = await m.repo.lastCommitMessage();
        const hasParent = await m.repo.refExists('HEAD~1');
        base = hasParent ? 'HEAD~1' : null;
        const known = new Set(files.map((f) => f.path));
        for (const f of await m.repo.changedFiles(hasParent ? 'HEAD~1' : null, 'HEAD')) {
          if (!known.has(f.path)) files.push(f);
        }
      }
      if (!base) files = files.map((f) => ({ path: f.path, type: /** @type {const} */ ('untracked') }));

      const perFile = await m.repo.diffPerFile(files, base);
      // Files committed line by line: describe only the selected lines.
      if (!amend && m.lineSelections.size) {
        try {
          const { filteredPatch } = require('./lineSelection');
          for (const p of await m.selectedContents()) perFile.set(p.path, filteredPatch(p.path, p.parsed, p.sel.excluded));
        } catch { /* selection out of date: fall back to the full diff */ }
      }
      let diff = '';
      const omitted = [];
      for (const [file, text] of perFile) {
        if (text.length > MAX_FILE_DIFF || diff.length + text.length > MAX_TOTAL_DIFF) {
          omitted.push(file);
          diff += `diff of ${file} omitted: too large (${text.split('\n').length} lines)\n`;
        } else {
          diff += text;
        }
      }

      const ai = this.ai = createAi(p, { apiKey, model: this.model() });
      m.log(`Generating commit message with ${this.model()} (${files.length} files, ${diff.length} chars of diff)…`);
      const message = await vscode.window.withProgress(
        { location: vscode.ProgressLocation.Window, title: 'Generating commit message' },
        async () => ai.generate({
          files: files.map((f) => `${f.type}: ${f.path}`),
          diff,
          branch: s.branch || '',
          recentSubjects: s.head ? await m.repo.recentSubjects() : [],
          language: String(this.cfg.get('ai.language') || ''),
          instructions: String(this.cfg.get('ai.instructions') || ''),
          amendOf,
        }, write),
      );
      write(message);
      if (omitted.length) {
        vscode.window.showInformationMessage(
          `Commit message generated. Large diffs were left out and only listed by name: ${omitted.slice(0, 5).join(', ')}${omitted.length > 5 ? ', …' : ''}`);
      }
    } catch (e) {
      if (scmInput) scmInput.value = previous;
      else write(previous);
      if (!(e instanceof AiError && e.cancelled)) {
        m.log(`Generate commit message failed: ${e.message}`, 'error');
        const r = await vscode.window.showErrorMessage(`Generate commit message failed: ${e.message}`, 'Configure…', 'Setup Guide');
        if (r === 'Configure…') this.configure();
        else if (r === 'Setup Guide') vscode.commands.executeCommand('gitTools.ai.setupGuide');
      }
    } finally {
      this.ai = null;
      this.setGenerating(false);
    }
  }

  /** Guided setup: provider, model, API key, connection test. */
  async configure() {
    const current = this.provider();
    const pick = /** @type {any} */ (await vscode.window.showQuickPick([
      { label: '$(sparkle) Google Gemini', description: 'has a free tier', id: 'gemini' },
      { label: '$(sparkle) Anthropic Claude', description: 'paid API', id: 'claude' },
      { label: '$(circle-slash) Not configured', description: 'disable AI commit messages', id: 'none' },
      { label: '$(book) Open Setup Guide', id: 'guide' },
    ].map((x) => ({ ...x, picked: x.id === current })), { title: 'AI Commit Message · Provider' }));
    if (!pick) return;
    if (pick.id === 'guide') return vscode.commands.executeCommand('gitTools.ai.setupGuide');
    if (pick.id === 'none') {
      await this.cfg.update('ai.provider', 'none', vscode.ConfigurationTarget.Global);
      vscode.window.showInformationMessage('AI commit messages disabled. Stored API keys were kept; use "Remove API Key" to delete them.');
      return;
    }
    const p = pick.id;
    const model = await this.pickModel(p);
    if (!model) return;
    if (!this.hasKey[p] || (await vscode.window.showQuickPick(['Keep the stored API key', 'Enter a new API key'], { title: `${PROVIDER_NAME[p]} API key` })) === 'Enter a new API key') {
      if (!(await this.setApiKey(p))) return;
    }
    await this.cfg.update('ai.provider', p, vscode.ConfigurationTarget.Global);
    await this.cfg.update(MODEL_SETTING[p], model, vscode.ConfigurationTarget.Global);
    await this.testConnection();
  }

  async pickModel(p) {
    const current = String(this.cfg.get(MODEL_SETTING[p]) || '');
    const qp = vscode.window.createQuickPick();
    qp.title = `${PROVIDER_NAME[p]} · Model`;
    qp.placeholder = 'Choose a suggestion or type a model id';
    qp.value = current;
    const base = SUGGESTIONS[p];
    const refresh = () => {
      const v = qp.value.trim();
      qp.items = v && !base.some((s) => s.label === v) ? [{ label: v, description: 'custom' }, ...base] : base;
    };
    refresh();
    qp.onDidChangeValue(refresh);
    const model = await new Promise((resolve) => {
      qp.onDidAccept(() => {
        resolve((qp.selectedItems[0] && qp.selectedItems[0].label) || qp.value.trim() || null);
        qp.hide();
      });
      qp.onDidHide(() => resolve(null));
      qp.show();
    });
    qp.dispose();
    return model;
  }

  async setApiKey(provider) {
    let p = provider;
    if (!p) {
      const pick = /** @type {any} */ (await vscode.window.showQuickPick([
        { label: 'Google Gemini', id: 'gemini' }, { label: 'Anthropic Claude', id: 'claude' },
      ], { title: 'Set API key for' }));
      if (!pick) return false;
      p = pick.id;
    }
    const key = await vscode.window.showInputBox({
      title: `${PROVIDER_NAME[p]} API key`,
      prompt: p === 'gemini' ? 'Create one at aistudio.google.com/apikey' : 'Create one at platform.claude.com/settings/keys',
      password: true,
      ignoreFocusOut: true,
      validateInput: (v) => (v.trim() ? null : 'Paste your API key'),
    });
    if (!key) return false;
    await this.context.secrets.store(SECRET[p], key.trim());
    await this.loadKeys();
    vscode.window.setStatusBarMessage(`$(key) ${PROVIDER_NAME[p]} API key saved in Secret Storage`, 4000);
    return true;
  }

  async clearApiKey() {
    const items = ['claude', 'gemini'].filter((p) => this.hasKey[p]).map((p) => ({ label: PROVIDER_NAME[p], id: p }));
    if (!items.length) {
      vscode.window.showInformationMessage('No API keys are stored.');
      return;
    }
    const pick = /** @type {any} */ (await vscode.window.showQuickPick(items, { title: 'Remove API key' }));
    if (!pick) return;
    await this.context.secrets.delete(SECRET[pick.id]);
    await this.loadKeys();
    vscode.window.showInformationMessage(`${pick.label} API key removed.`);
  }

  async testConnection() {
    const p = this.provider();
    if (p === 'none') return this.notConfigured();
    const apiKey = await this.context.secrets.get(SECRET[p]);
    if (!apiKey || !this.model()) return this.notConfigured();
    try {
      await vscode.window.withProgress(
        { location: vscode.ProgressLocation.Notification, title: `Testing ${PROVIDER_NAME[p]} (${this.model()})…` },
        () => createAi(p, { apiKey, model: this.model() }).testConnection(),
      );
      vscode.window.showInformationMessage(`AI commit message is ready: ${PROVIDER_NAME[p]} · ${this.model()}.`);
    } catch (e) {
      const r = await vscode.window.showErrorMessage(`Connection test failed: ${e.message}`, 'Configure…', 'Setup Guide');
      if (r === 'Configure…') this.configure();
      else if (r === 'Setup Guide') vscode.commands.executeCommand('gitTools.ai.setupGuide');
    }
  }
}

/** Input box of the built-in Git extension for the repository at root. */
function scmInputBox(root) {
  try {
    const ext = vscode.extensions.getExtension('vscode.git');
    if (!ext || !ext.isActive) return null;
    const api = ext.exports.getAPI(1);
    const norm = (p) => p.replace(/\\/g, '/').toLowerCase();
    const repo = api.repositories.find((r) => norm(r.rootUri.fsPath) === norm(root)) || api.repositories[0];
    return repo ? repo.inputBox : null;
  } catch {
    return null;
  }
}

module.exports = { AiController, SUGGESTIONS };
