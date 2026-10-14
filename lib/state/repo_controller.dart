import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../ai/commit_message_ai.dart';
import '../git/git_process.dart';
import '../git/git_repository.dart';
import '../git/graph_layout.dart';
import '../git/models.dart';
import 'app_settings.dart';

enum GenerateResult { done, needsSetup, failed }

class AppNotification {
  AppNotification(this.title, {this.details, this.isError = false})
      : id = _next++;

  static int _next = 0;
  final int id;
  final String title;
  final String? details;
  final bool isError;
}

/// A tab in the central editor area.
sealed class EditorTab {
  String get key;
  String get title;
}

class DiffTab extends EditorTab {
  DiffTab(this.request);
  final DiffRequest request;

  @override
  String get key => 'diff:${request.key}';
  @override
  String get title => request.title;
}

class BlameTab extends EditorTab {
  BlameTab(this.path);
  final String path;

  @override
  String get key => 'blame:$path';
  @override
  String get title => '${p.basename(path)} (Annotate)';
}

class LogFilter {
  const LogFilter({this.branch, this.path, this.text = ''});

  /// Ref to show (null = all branches).
  final String? branch;

  /// Show history for this path only.
  final String? path;

  /// Client side filter on subject / hash / author.
  final String text;

  LogFilter copyWith({
    String? Function()? branch,
    String? Function()? path,
    String? text,
  }) =>
      LogFilter(
        branch: branch != null ? branch() : this.branch,
        path: path != null ? path() : this.path,
        text: text ?? this.text,
      );
}

class RepoController {
  RepoController(String root) {
    repo = GitRepository(root, onConsole: _addConsole);
  }

  late final GitRepository repo;

  final status = ValueNotifier<RepoStatus>(const RepoStatus());
  final branches = ValueNotifier<List<Branch>>(const []);
  final tags = ValueNotifier<List<Tag>>(const []);
  final remotes = ValueNotifier<List<Remote>>(const []);
  final stashes = ValueNotifier<List<Stash>>(const []);
  final commits = ValueNotifier<List<Commit>>(const []);
  final graph = ValueNotifier<List<GraphRow>>(const []);
  final logFilter = ValueNotifier<LogFilter>(const LogFilter());
  final logLoading = ValueNotifier<bool>(false);
  final selectedCommit = ValueNotifier<Commit?>(null);

  final console = ValueNotifier<List<ConsoleEntry>>(const []);
  final busy = ValueNotifier<String?>(null);
  final notifications = ValueNotifier<AppNotification?>(null);

  final tabs = ValueNotifier<List<EditorTab>>(const []);
  final activeTab = ValueNotifier<String?>(null);

  /// Bottom tool window tab requested by actions (0 = Log, 1 = Console...).
  final bottomTab = ValueNotifier<int>(0);

  // Changes view inclusion (Android Studio checkbox model).
  final included = ValueNotifier<Set<String>>(const {});
  final Set<String> _excludedTracked = {};
  final Set<String> _includedUntracked = {};

  final commitMessage = TextEditingController();
  final amend = ValueNotifier<bool>(false);
  String _messageBeforeAmend = '';
  String? _prefilledMessage;

  StreamSubscription<FileSystemEvent>? _watch;
  Timer? _debounce;
  bool _refsDirty = false;
  bool _disposed = false;
  int _logGen = 0;

  String get root => repo.root;
  String get name => repo.name;

  Future<void> open() async {
    await refreshAll();
    final msg = await repo.pendingMergeMessage();
    if (msg != null && commitMessage.text.isEmpty) {
      commitMessage.text = msg;
      _prefilledMessage = msg;
    }
    _startWatching();
  }

  void dispose() {
    _disposed = true;
    _ai?.cancel();
    _watch?.cancel();
    _debounce?.cancel();
    commitMessage.dispose();
  }

  // ---------------------------------------------------------------------------
  // Refresh
  // ---------------------------------------------------------------------------

  Future<void> refreshAll() async {
    await Future.wait([
      refreshStatus(),
      refreshRefs(),
    ]);
    await refreshLog();
  }

  Future<void> refreshStatus() async {
    try {
      final s = await repo.status();
      if (_disposed) return;
      final previous = status.value.state;
      status.value = s;
      _recomputeIncluded();
      // Prefill the prepared message when a merge / cherry-pick starts.
      if (previous == RepoState.normal &&
          s.state != RepoState.normal &&
          commitMessage.text.trim().isEmpty) {
        final msg = await repo.pendingMergeMessage();
        if (msg != null && !_disposed) {
          commitMessage.text = msg;
          _prefilledMessage = msg;
        }
      } else if (s.state == RepoState.normal &&
          _prefilledMessage != null &&
          commitMessage.text.trim() == _prefilledMessage!.trim()) {
        // The operation was continued or aborted outside the commit box.
        commitMessage.clear();
        _prefilledMessage = null;
      }
    } catch (e) {
      _addConsole(ConsoleEntry('status failed: $e', ConsoleKind.error));
    }
  }

  Future<void> refreshRefs() async {
    try {
      final results = await Future.wait([
        repo.branches(),
        repo.tags(),
        repo.remotes(),
        repo.stashes(),
      ]);
      if (_disposed) return;
      branches.value = results[0] as List<Branch>;
      tags.value = results[1] as List<Tag>;
      remotes.value = results[2] as List<Remote>;
      stashes.value = results[3] as List<Stash>;
    } catch (e) {
      _addConsole(ConsoleEntry('refs failed: $e', ConsoleKind.error));
    }
  }

  Future<void> refreshLog() async {
    final gen = ++_logGen;
    logLoading.value = true;
    try {
      final f = logFilter.value;
      final list = await repo.log(
        revisions: f.branch == null ? null : [f.branch!],
        path: f.path,
      );
      if (_disposed || gen != _logGen) return;
      commits.value = list;
      graph.value = layoutGraph(list);
      final sel = selectedCommit.value;
      if (sel != null) {
        selectedCommit.value =
            list.where((c) => c.hash == sel.hash).firstOrNull;
      }
    } catch (e) {
      _addConsole(ConsoleEntry('log failed: $e', ConsoleKind.error));
    } finally {
      if (gen == _logGen) logLoading.value = false;
    }
  }

  void setLogFilter(LogFilter f) {
    final old = logFilter.value;
    logFilter.value = f;
    if (old.branch != f.branch || old.path != f.path) refreshLog();
  }

  void showHistory(String path) {
    setLogFilter(logFilter.value.copyWith(path: () => path, branch: () => null));
    bottomTab.value = 0;
  }

  void _startWatching() {
    try {
      _watch = Directory(root).watch(recursive: true).listen(_onFsEvent);
    } catch (e) {
      _addConsole(ConsoleEntry('File watching unavailable: $e', ConsoleKind.info));
    }
  }

  void _onFsEvent(FileSystemEvent e) {
    final rel = p.relative(e.path, from: root).replaceAll('\\', '/');
    if (rel == '.git' || rel.startsWith('.git/')) {
      if (rel.endsWith('.lock') ||
          rel.startsWith('.git/objects') ||
          rel.startsWith('.git/logs')) {
        return;
      }
      if (rel.startsWith('.git/refs') ||
          rel == '.git/HEAD' ||
          rel == '.git/packed-refs' ||
          rel == '.git/FETCH_HEAD' ||
          rel == '.git/MERGE_HEAD' ||
          rel.startsWith('.git/rebase-')) {
        _refsDirty = true;
      } else if (rel != '.git/index') {
        return;
      }
    }
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () {
      if (busy.value != null) return; // refreshed when the operation ends
      if (_refsDirty) {
        _refsDirty = false;
        refreshAll();
      } else {
        refreshStatus();
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Inclusion
  // ---------------------------------------------------------------------------

  void _recomputeIncluded() {
    final s = status.value;
    final paths = {for (final c in s.changes) c.path};
    _excludedTracked.removeWhere((p) => !paths.contains(p));
    _includedUntracked.removeWhere((p) => !paths.contains(p));
    included.value = {
      for (final c in s.changes)
        if (c.type == ChangeType.untracked
            ? _includedUntracked.contains(c.path)
            : !_excludedTracked.contains(c.path))
          c.path,
    };
  }

  void setIncluded(Iterable<FileChange> changes, bool value) {
    for (final c in changes) {
      final untracked = c.type == ChangeType.untracked;
      if (untracked) {
        value ? _includedUntracked.add(c.path) : _includedUntracked.remove(c.path);
      } else {
        value ? _excludedTracked.remove(c.path) : _excludedTracked.add(c.path);
      }
    }
    _recomputeIncluded();
  }

  List<FileChange> get includedChanges => status.value.changes
      .where((c) => included.value.contains(c.path))
      .toList();

  // ---------------------------------------------------------------------------
  // Operations
  // ---------------------------------------------------------------------------

  /// Runs a git operation with progress indication and error reporting.
  /// Returns false when it failed.
  Future<bool> run(
    String label,
    Future<void> Function() action, {
    String? success,
    bool refresh = true,
  }) async {
    busy.value = label;
    _addConsole(ConsoleEntry('$label…', ConsoleKind.info));
    try {
      await action();
      if (success != null) notify(AppNotification(success));
      return true;
    } on GitException catch (e) {
      notify(AppNotification('$label failed', details: e.message, isError: true));
      return false;
    } catch (e) {
      notify(AppNotification('$label failed', details: '$e', isError: true));
      return false;
    } finally {
      busy.value = null;
      if (refresh && !_disposed) await refreshAll();
    }
  }

  void notify(AppNotification n) {
    if (_disposed) return;
    notifications.value = n;
    if (n.isError) {
      _addConsole(ConsoleEntry('${n.title}: ${n.details ?? ''}', ConsoleKind.error));
    }
  }

  Future<void> toggleAmend(bool value) async {
    amend.value = value;
    if (value) {
      _messageBeforeAmend = commitMessage.text;
      if (commitMessage.text.trim().isEmpty && status.value.hasCommits) {
        commitMessage.text = await repo.lastCommitMessage();
      }
    } else {
      commitMessage.text = _messageBeforeAmend;
    }
  }

  Future<bool> commit({bool signOff = false, String? author}) async {
    final message = commitMessage.text.trim();
    final changes = includedChanges;
    final s = status.value;
    final inMerge = s.state != RepoState.normal;
    if (message.isEmpty) {
      notify(AppNotification('Commit message is empty', isError: true));
      return false;
    }
    if (changes.isEmpty && !amend.value && !inMerge) {
      notify(AppNotification('No changes selected for commit', isError: true));
      return false;
    }
    if (s.conflicts.isNotEmpty) {
      notify(AppNotification('Resolve all conflicts before committing',
          isError: true));
      return false;
    }
    final paths = changes.expand((c) => c.allPaths).toSet().toList();
    final ok = await run(
      amend.value ? 'Amend commit' : 'Commit',
      () => repo.commit(
        message: message,
        paths: paths,
        amend: amend.value,
        signOff: signOff,
        author: author,
        partial: !inMerge,
      ),
      success: amend.value
          ? 'Amended commit'
          : '${changes.length} file${changes.length == 1 ? '' : 's'} committed: ${message.split('\n').first}',
    );
    if (ok) {
      commitMessage.clear();
      amend.value = false;
      _messageBeforeAmend = '';
      _includedUntracked.clear();
      _excludedTracked.clear();
    }
    return ok;
  }

  // ---------------------------------------------------------------------------
  // AI commit message
  // ---------------------------------------------------------------------------

  final generating = ValueNotifier<bool>(false);
  CommitMessageAi? _ai;

  static const _maxFileDiff = 40000;
  static const _maxTotalDiff = 150000;

  void cancelGeneration() => _ai?.cancel();

  /// Fills the commit message box with a message generated from the
  /// selected changes (or the amended commit).
  Future<GenerateResult> generateCommitMessage(AppSettings settings) async {
    if (!settings.aiConfigured) return GenerateResult.needsSetup;
    if (generating.value) return GenerateResult.failed;
    final s = status.value;
    final changes = includedChanges
        .where((c) => c.type != ChangeType.conflicted)
        .toList();
    final isAmend = amend.value && s.hasCommits;
    if (changes.isEmpty && !isAmend) {
      notify(AppNotification('Select the files to commit first',
          details: 'The message is generated from the checked changes.', isError: true));
      return GenerateResult.failed;
    }

    final previous = commitMessage.text;
    generating.value = true;
    try {
      // Amending includes the last commit's own changes.
      String? base = s.hasCommits ? 'HEAD' : null;
      final files = [...changes];
      String? amendOf;
      if (isAmend) {
        amendOf = await repo.lastCommitMessage();
        final hasParent = await repo.refExists('HEAD~1');
        base = hasParent ? 'HEAD~1' : null;
        final headFiles = await repo.changedFiles(hasParent ? 'HEAD~1' : null, 'HEAD');
        final known = files.map((f) => f.path).toSet();
        files.addAll(headFiles.where((f) => known.add(f.path)));
      }
      if (base == null) {
        // No parent commit: everything is a new file.
        for (var i = 0; i < files.length; i++) {
          files[i] = FileChange(path: files[i].path, type: ChangeType.added);
        }
      }

      final perFile = await repo.diffPerFile(
        base == null
            ? files.map((f) => FileChange(path: f.path, type: ChangeType.untracked)).toList()
            : files,
        base: base,
      );
      final diff = StringBuffer();
      final omitted = <String>[];
      for (final entry in perFile.entries) {
        final text = entry.value;
        if (text.length > _maxFileDiff || diff.length + text.length > _maxTotalDiff) {
          omitted.add(entry.key);
          diff.writeln('diff of ${entry.key} omitted: too large '
              '(${'\n'.allMatches(text).length} lines)');
        } else {
          diff.write(text);
        }
      }

      final req = CommitMessageRequest(
        branch: s.branch ?? '',
        files: [for (final f in files) '${f.type.label}: ${f.path}'],
        diff: diff.toString(),
        recentSubjects: s.hasCommits ? await repo.recentSubjects() : const [],
        language: settings.aiLanguage,
        instructions: settings.aiInstructions,
        amendOf: amendOf,
      );

      final ai = _ai = switch (settings.aiProvider) {
        AiProvider.claude => ClaudeCommitAi(apiKey: settings.aiApiKey, model: settings.aiModel),
        AiProvider.gemini => GeminiCommitAi(apiKey: settings.aiApiKey, model: settings.aiModel),
        AiProvider.none => throw StateError('No AI provider'),
      };
      _addConsole(ConsoleEntry(
          'Generating commit message with ${settings.aiModel} '
          '(${files.length} files, ${diff.length} chars of diff)…',
          ConsoleKind.info));
      final message = await ai.generate(req, onText: (t) {
        if (!_disposed) commitMessage.text = t;
      });
      if (_disposed) return GenerateResult.done;
      commitMessage.text = message;
      if (omitted.isNotEmpty) {
        notify(AppNotification('Commit message generated',
            details: 'Large diffs were left out and only listed by name: '
                '${omitted.take(5).join(', ')}${omitted.length > 5 ? ', …' : ''}'));
      }
      return GenerateResult.done;
    } on AiException catch (e) {
      if (!_disposed) {
        commitMessage.text = previous;
        if (!e.cancelled) {
          notify(AppNotification('Generate commit message failed',
              details: e.message, isError: true));
        }
      }
      return GenerateResult.failed;
    } catch (e) {
      if (!_disposed) {
        commitMessage.text = previous;
        notify(AppNotification('Generate commit message failed', details: '$e', isError: true));
      }
      return GenerateResult.failed;
    } finally {
      _ai = null;
      if (!_disposed) generating.value = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Editor tabs
  // ---------------------------------------------------------------------------

  /// Key of the tab opened in preview mode (replaced by the next preview).
  final previewTab = ValueNotifier<String?>(null);

  void openTab(EditorTab tab, {bool preview = false}) {
    final list = [...tabs.value];
    final existing = list.indexWhere((t) => t.key == tab.key);
    if (existing >= 0) {
      if (!preview && previewTab.value == tab.key) previewTab.value = null;
    } else if (preview) {
      final pi = list.indexWhere((t) => t.key == previewTab.value);
      if (pi >= 0) {
        list[pi] = tab;
      } else {
        list.add(tab);
      }
      previewTab.value = tab.key;
    } else {
      list.add(tab);
    }
    tabs.value = list;
    activeTab.value = tab.key;
  }

  void closeTab(String key) {
    final list = [...tabs.value];
    final i = list.indexWhere((t) => t.key == key);
    if (i < 0) return;
    list.removeAt(i);
    if (previewTab.value == key) previewTab.value = null;
    tabs.value = list;
    if (activeTab.value == key) {
      activeTab.value =
          list.isEmpty ? null : list[i.clamp(0, list.length - 1)].key;
    }
  }

  void closeAllTabs() {
    tabs.value = const [];
    activeTab.value = null;
    previewTab.value = null;
  }

  /// Diff of a working tree change against HEAD.
  void showLocalDiff(FileChange c, {bool preview = false}) =>
      openTab(DiffTab(localDiffRequest(c)), preview: preview);

  DiffRequest localDiffRequest(FileChange c) {
    final hasHead = status.value.hasCommits;
    final Revision left = switch (c.type) {
      ChangeType.untracked || ChangeType.added => const EmptyRev(),
      _ => hasHead ? const CommitRev('HEAD') : const IndexRev(),
    };
    final Revision right = c.type == ChangeType.deleted
        ? const EmptyRev()
        : const WorkingTreeRev();
    return DiffRequest(
      title: c.fileName,
      leftPath: c.oldPath ?? c.path,
      rightPath: c.path,
      left: left,
      right: right,
      leftTitle: left is EmptyRev ? '(does not exist)' : 'HEAD',
      rightTitle: right is EmptyRev ? '(deleted)' : 'Your version',
    );
  }

  /// Diff of a file changed in commit [hash] relative to [parent].
  void showCommitDiff(FileChange f, String hash, String? parent,
      {String? titleSuffix, bool preview = false}) {
    openTab(DiffTab(commitDiffRequest(f, hash, parent, titleSuffix: titleSuffix)),
        preview: preview);
  }

  DiffRequest commitDiffRequest(FileChange f, String hash, String? parent,
      {String? titleSuffix}) {
    final short = shortRef(hash);
    final pShort = parent == null ? '' : shortRef(parent);
    final Revision left = parent == null ||
            f.type == ChangeType.added ||
            f.type == ChangeType.untracked
        ? const EmptyRev()
        : CommitRev(parent);
    final Revision right =
        f.type == ChangeType.deleted ? const EmptyRev() : CommitRev(hash);
    return DiffRequest(
      title: '${f.fileName} ${titleSuffix ?? '($short)'}',
      leftPath: f.oldPath ?? f.path,
      rightPath: f.path,
      left: left,
      right: right,
      leftTitle: left is EmptyRev ? '(does not exist)' : pShort,
      rightTitle: right is EmptyRev ? '(deleted)' : short,
    );
  }

  static final _fullHash = RegExp(r'^[0-9a-f]{40}');

  /// Abbreviates full commit hashes, keeps symbolic refs.
  static String shortRef(String ref) => _fullHash.hasMatch(ref)
      ? ref.substring(0, 8) + ref.substring(40)
      : ref;

  // ---------------------------------------------------------------------------
  // Console
  // ---------------------------------------------------------------------------

  void _addConsole(ConsoleEntry e) {
    if (_disposed) return;
    final list = [...console.value, e];
    console.value =
        list.length > 5000 ? list.sublist(list.length - 5000) : list;
  }

  void clearConsole() => console.value = const [];

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Branch? get currentBranch =>
      branches.value.where((b) => b.isCurrent).firstOrNull;

  /// Default remote for push / pull.
  String? get defaultRemote {
    final up = status.value.upstream;
    if (up != null && up.contains('/')) return up.substring(0, up.indexOf('/'));
    final r = remotes.value;
    if (r.isEmpty) return null;
    return r.any((e) => e.name == 'origin') ? 'origin' : r.first.name;
  }
}
