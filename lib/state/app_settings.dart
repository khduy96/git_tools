import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

/// AI service used to generate commit messages.
enum AiProvider { none, claude, gemini }

/// Persistent app settings stored as JSON in the user's app data folder.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._file);

  final File _file;
  List<String> recentRepos = [];
  bool sideBySide = true;
  bool collapseUnchanged = true;
  bool ignoreWhitespace = false;
  bool pullRebase = false;
  String? lastCloneDir;

  // AI commit message generation. Nothing is preconfigured: the user picks
  // the provider, key and model.
  AiProvider aiProvider = AiProvider.none;
  String claudeApiKey = '';
  String claudeModel = '';
  String geminiApiKey = '';
  String geminiModel = '';
  String aiLanguage = '';
  String aiInstructions = '';

  String get settingsPath => _file.path;

  String get aiApiKey => switch (aiProvider) {
        AiProvider.claude => claudeApiKey.trim(),
        AiProvider.gemini => geminiApiKey.trim(),
        AiProvider.none => '',
      };

  String get aiModel => switch (aiProvider) {
        AiProvider.claude => claudeModel.trim(),
        AiProvider.gemini => geminiModel.trim(),
        AiProvider.none => '',
      };

  bool get aiConfigured =>
      aiProvider != AiProvider.none && aiApiKey.isNotEmpty && aiModel.isNotEmpty;

  static Future<AppSettings> load() async {
    final base = Platform.environment['APPDATA'] ??
        Platform.environment['XDG_CONFIG_HOME'] ??
        p.join(Platform.environment['HOME'] ?? '.', '.config');
    final file = File(p.join(base, 'git_tools', 'settings.json'));
    final s = AppSettings._(file);
    try {
      if (await file.exists()) {
        final j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        s.recentRepos = (j['recentRepos'] as List? ?? []).cast<String>();
        s.sideBySide = j['sideBySide'] as bool? ?? true;
        s.collapseUnchanged = j['collapseUnchanged'] as bool? ?? true;
        s.ignoreWhitespace = j['ignoreWhitespace'] as bool? ?? false;
        s.pullRebase = j['pullRebase'] as bool? ?? false;
        s.lastCloneDir = j['lastCloneDir'] as String?;
        s.aiProvider = AiProvider.values
                .where((v) => v.name == j['aiProvider'])
                .firstOrNull ??
            AiProvider.none;
        s.claudeApiKey = j['claudeApiKey'] as String? ?? '';
        s.claudeModel = j['claudeModel'] as String? ?? '';
        s.geminiApiKey = j['geminiApiKey'] as String? ?? '';
        s.geminiModel = j['geminiModel'] as String? ?? '';
        s.aiLanguage = j['aiLanguage'] as String? ?? '';
        s.aiInstructions = j['aiInstructions'] as String? ?? '';
      }
    } catch (_) {
      // Corrupt settings are ignored.
    }
    return s;
  }

  Future<void> save() async {
    notifyListeners();
    try {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(const JsonEncoder.withIndent('  ').convert({
        'recentRepos': recentRepos,
        'sideBySide': sideBySide,
        'collapseUnchanged': collapseUnchanged,
        'ignoreWhitespace': ignoreWhitespace,
        'pullRebase': pullRebase,
        'lastCloneDir': lastCloneDir,
        'aiProvider': aiProvider.name,
        'claudeApiKey': claudeApiKey,
        'claudeModel': claudeModel,
        'geminiApiKey': geminiApiKey,
        'geminiModel': geminiModel,
        'aiLanguage': aiLanguage,
        'aiInstructions': aiInstructions,
      }));
    } catch (_) {}
  }

  Future<void> addRecent(String path) async {
    recentRepos.remove(path);
    recentRepos.insert(0, path);
    if (recentRepos.length > 20) recentRepos = recentRepos.sublist(0, 20);
    await save();
  }

  Future<void> removeRecent(String path) async {
    recentRepos.remove(path);
    await save();
  }
}
