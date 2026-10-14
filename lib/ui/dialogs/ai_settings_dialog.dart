import 'package:flutter/material.dart';

import '../../ai/commit_message_ai.dart';
import '../../state/app_settings.dart';
import '../common.dart';
import 'ai_setup_guide.dart';
import 'basic_dialogs.dart';

/// Settings for AI generated commit messages. Nothing is preselected.
Future<bool> showAiSettingsDialog(BuildContext context, AppSettings settings) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (_) => _AiSettingsDialog(settings: settings),
  );
  return r ?? false;
}

class _ProviderInfo {
  const _ProviderInfo(this.name, this.keyUrl, this.modelHint, this.suggestions, this.note);

  final String name;
  final String keyUrl;
  final String modelHint;
  final List<String> suggestions;
  final String note;
}

const _providers = {
  AiProvider.claude: _ProviderInfo(
    'Anthropic Claude',
    'console.anthropic.com → API Keys',
    'e.g. claude-opus-5-5',
    ['claude-opus-5-5', 'claude-sonnet-5-5', 'claude-haiku-5-5'],
    'Paid API: billed per token on your Anthropic account.',
  ),
  AiProvider.gemini: _ProviderInfo(
    'Google Gemini',
    'aistudio.google.com → Get API key',
    'e.g. gemini-3.8-flash',
    ['gemini-3.8-flash', 'gemini-3.5-flash-lite', 'gemini-2.5-flash-lite'],
    'Free tier has daily request limits, and Google may use free-tier '
        'requests (your diffs) to improve its products. Check your '
        'company policy before sending private code.',
  ),
};

class _AiSettingsDialog extends StatefulWidget {
  const _AiSettingsDialog({required this.settings});

  final AppSettings settings;

  @override
  State<_AiSettingsDialog> createState() => _AiSettingsDialogState();
}

class _AiSettingsDialogState extends State<_AiSettingsDialog> {
  AppSettings get s => widget.settings;

  late AiProvider _provider = s.aiProvider;
  late final _claudeKey = TextEditingController(text: s.claudeApiKey);
  late final _claudeModel = TextEditingController(text: s.claudeModel);
  late final _geminiKey = TextEditingController(text: s.geminiApiKey);
  late final _geminiModel = TextEditingController(text: s.geminiModel);
  late final _language = TextEditingController(text: s.aiLanguage);
  late final _instructions = TextEditingController(text: s.aiInstructions);
  bool _showKey = false;
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_claudeKey, _claudeModel, _geminiKey, _geminiModel, _language, _instructions]) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController get _key => _provider == AiProvider.claude ? _claudeKey : _geminiKey;
  TextEditingController get _model => _provider == AiProvider.claude ? _claudeModel : _geminiModel;

  String? _validate() {
    if (_provider == AiProvider.none) return null;
    if (_key.text.trim().isEmpty) return 'Enter an API key';
    if (_model.text.trim().isEmpty) return 'Enter a model name';
    return null;
  }

  Future<void> _test() async {
    final err = _validate();
    if (err != null || _provider == AiProvider.none) {
      setState(() => _error = err ?? 'Choose a provider first');
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
      _error = null;
    });
    final ai = _provider == AiProvider.claude
        ? ClaudeCommitAi(apiKey: _key.text.trim(), model: _model.text.trim())
        : GeminiCommitAi(apiKey: _key.text.trim(), model: _model.text.trim());
    try {
      await ai.testConnection();
      _testOk = true;
      _testResult = 'Connection OK';
    } on AiException catch (e) {
      _testOk = false;
      _testResult = e.message;
    } catch (e) {
      _testOk = false;
      _testResult = '$e';
    }
    if (mounted) setState(() => _testing = false);
  }

  void _save() {
    final err = _validate();
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    s
      ..aiProvider = _provider
      ..claudeApiKey = _claudeKey.text.trim()
      ..claudeModel = _claudeModel.text.trim()
      ..geminiApiKey = _geminiKey.text.trim()
      ..geminiModel = _geminiModel.text.trim()
      ..aiLanguage = _language.text.trim()
      ..aiInstructions = _instructions.text.trim();
    s.save();
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final info = _providers[_provider];
    const label = TextStyle(fontSize: 13, color: AppColors.textDim);
    const hint = TextStyle(fontSize: 12, color: AppColors.textMuted, height: 1.4);
    return AppDialog(
      title: 'AI Commit Message',
      width: 560,
      onSubmit: _save,
      leftActions: [
        if (_provider != AiProvider.none)
          OutlinedButton(
            onPressed: _testing ? null : _test,
            child: _testing
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5))
                : const Text('Test Connection'),
          ),
      ],
      actions: [
        OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Text('Provider', style: label),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.menu_book_outlined, size: 15),
                label: const Text('Setup guide'),
                onPressed: () => showAiSetupGuide(context,
                    initial: _provider == AiProvider.none ? null : _provider),
              ),
            ]),
            RadioGroup<AiProvider>(
              groupValue: _provider,
              onChanged: (v) => setState(() {
                _provider = v!;
                _error = null;
                _testResult = null;
              }),
              child: Wrap(
                spacing: 16,
                children: [
                  for (final (value, text) in [
                    (AiProvider.none, 'Not configured'),
                    (AiProvider.claude, 'Anthropic Claude'),
                    (AiProvider.gemini, 'Google Gemini'),
                  ])
                    InkWell(
                      onTap: () => setState(() {
                        _provider = value;
                        _error = null;
                        _testResult = null;
                      }),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Radio<AiProvider>(value: value),
                        Text(text, style: const TextStyle(fontSize: 13)),
                      ]),
                    ),
                ],
              ),
            ),
            if (info == null)
              Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.08),
                  border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Row(children: [
                  const Expanded(
                    child: Text(
                      'AI commit messages are disabled until you choose a provider and enter your own API key. '
                      'New here? The setup guide walks you through getting a key.',
                      style: TextStyle(fontSize: 12.5, height: 1.4),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    icon: const Icon(Icons.menu_book_outlined, size: 15),
                    label: const Text('Open setup guide'),
                    onPressed: () => showAiSetupGuide(context),
                  ),
                ]),
              )
            else ...[
              const SizedBox(height: 12),
              Text('${info.name} API key', style: label),
              const SizedBox(height: 4),
              TextField(
                controller: _key,
                obscureText: !_showKey,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Paste your API key',
                  suffixIcon: IconButton(
                    iconSize: 16,
                    tooltip: _showKey ? 'Hide' : 'Show',
                    icon: Icon(_showKey ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                    onPressed: () => setState(() => _showKey = !_showKey),
                  ),
                ),
                onChanged: (_) => setState(() => _testResult = null),
              ),
              const SizedBox(height: 3),
              Text('Get a key at ${info.keyUrl}', style: hint),
              const SizedBox(height: 12),
              const Text('Model', style: label),
              const SizedBox(height: 4),
              TextField(
                controller: _model,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(hintText: info.modelHint),
                onChanged: (_) => setState(() => _testResult = null),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final m in info.suggestions)
                    ActionChip(
                      label: Text(m, style: const TextStyle(fontSize: 11.5)),
                      visualDensity: VisualDensity.compact,
                      side: BorderSide(
                          color: _model.text.trim() == m ? AppColors.accent : AppColors.border),
                      onPressed: () => setState(() {
                        _model.text = m;
                        _testResult = null;
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.08),
                  border: Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(info.note, style: hint),
              ),
            ],
            const SizedBox(height: 14),
            const Text('Message language (optional)', style: label),
            const SizedBox(height: 4),
            TextField(
              controller: _language,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                  hintText: 'e.g. English, Vietnamese. Empty: follow the repository history'),
            ),
            const SizedBox(height: 12),
            const Text('Extra instructions (optional)', style: label),
            const SizedBox(height: 4),
            TextField(
              controller: _instructions,
              minLines: 2,
              maxLines: 5,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                  hintText: 'e.g. Use Conventional Commits (feat:, fix:). Mention the Jira ticket from the branch name.'),
            ),
            const SizedBox(height: 10),
            Text('Keys are stored unencrypted in ${s.settingsPath}', style: hint),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: const TextStyle(fontSize: 12.5, color: AppColors.error)),
              ),
            if (_testResult != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(_testOk ? Icons.check_circle_outline : Icons.error_outline,
                      size: 15, color: _testOk ? AppColors.success : AppColors.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(_testResult!,
                        style: TextStyle(
                            fontSize: 12.5, color: _testOk ? AppColors.success : AppColors.error)),
                  ),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}
