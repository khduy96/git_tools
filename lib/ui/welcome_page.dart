import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../git/git_process.dart';
import '../git/git_repository.dart';
import '../state/app_settings.dart';
import 'common.dart';
import 'dialogs/basic_dialogs.dart';

/// Opens a folder picker and returns the repository root (initializing a
/// repository on request). Returns null when cancelled.
Future<String?> pickRepository(BuildContext context) async {
  final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Open Git Repository');
  if (dir == null || !context.mounted) return null;
  final root = await GitRepository.findRoot(dir);
  if (root != null) return root;
  if (!context.mounted) return null;
  final init = await showConfirm(context,
      title: 'Not a Git Repository',
      message: '"$dir" is not inside a Git repository.\nCreate a new repository there?',
      confirmLabel: 'Create Repository');
  if (!init) return null;
  await GitRepository.init(dir);
  return p.normalize(dir);
}

Future<String?> showCloneDialog(BuildContext context, AppSettings settings) =>
    showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CloneDialog(settings: settings),
    );

class WelcomePage extends StatefulWidget {
  const WelcomePage({
    super.key,
    required this.settings,
    required this.onOpen,
    this.gitVersion,
  });

  final AppSettings settings;
  final void Function(String root) onOpen;
  final String? gitVersion;

  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage> {
  final _filter = TextEditingController();

  Future<void> _open() async {
    final root = await pickRepository(context);
    if (root != null) widget.onOpen(root);
  }

  Future<void> _clone() async {
    final root = await showCloneDialog(context, widget.settings);
    if (root != null) widget.onOpen(root);
  }

  Future<void> _init() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Create Git Repository');
    if (dir == null) return;
    try {
      await GitRepository.init(dir);
      widget.onOpen(p.normalize(dir));
    } catch (e) {
      if (mounted) {
        showConfirm(context, title: 'Cannot create repository', message: '$e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _filter.text.trim().toLowerCase();
    final recent = widget.settings.recentRepos
        .where((r) => q.isEmpty || r.toLowerCase().contains(q))
        .toList();
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: 260,
            color: AppColors.panel,
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(colors: [Color(0xFF3574F0), Color(0xFF5FB865)]),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: const Icon(Icons.call_split, color: Colors.white),
                  ),
                  const SizedBox(width: 12),
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Git Tools', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                      Text('Android Studio style Git client',
                          style: TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
                    ],
                  ),
                ]),
                const SizedBox(height: 28),
                const Text('Repositories', style: TextStyle(fontSize: 13, color: AppColors.text)),
                const Spacer(),
                if (widget.gitVersion != null)
                  Text(widget.gitVersion!, style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _filter,
                        style: const TextStyle(fontSize: 13),
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search, size: 16),
                          prefixIconConstraints: BoxConstraints(minWidth: 30),
                          hintText: 'Search repositories',
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: _open,
                      icon: const Icon(Icons.folder_open, size: 16),
                      label: const Text('Open'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: _clone,
                      icon: const Icon(Icons.download, size: 16),
                      label: const Text('Clone'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: _init,
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('New Repository'),
                    ),
                  ]),
                  const SizedBox(height: 16),
                  Expanded(
                    child: recent.isEmpty
                        ? const EmptyHint(
                            'Open an existing Git repository, clone one from a URL,\nor create a new one.',
                            icon: Icons.folder_special_outlined)
                        : ListView(
                            children: [
                              for (final r in recent) _recentRow(r),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _recentRow(String path) {
    final exists = Directory(path).existsSync();
    final name = p.basename(path);
    return HoverRow(
      height: 50,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      onTap: exists ? () => widget.onOpen(path) : null,
      onSecondaryTapDown: (d) async {
        final r = await showContextMenu<String>(context, d.globalPosition, [
          menuItem('remove', 'Remove from Recent', icon: Icons.close),
        ]);
        if (r == 'remove') {
          await widget.settings.removeRecent(path);
          setState(() {});
        }
      },
      child: Row(children: [
        Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.graph[name.hashCode.abs() % AppColors.graph.length].withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            name.isEmpty ? '?' : name.substring(0, name.length >= 2 ? 2 : 1).toUpperCase(),
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, style: TextStyle(fontSize: 13.5, color: exists ? AppColors.text : AppColors.textMuted)),
              Text(exists ? path : '$path (missing)',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
            ],
          ),
        ),
        ToolButton(
          icon: Icons.close,
          tooltip: 'Remove from Recent',
          onPressed: () async {
            await widget.settings.removeRecent(path);
            setState(() {});
          },
        ),
      ]),
    );
  }
}

class _CloneDialog extends StatefulWidget {
  const _CloneDialog({required this.settings});

  final AppSettings settings;

  @override
  State<_CloneDialog> createState() => _CloneDialogState();
}

class _CloneDialogState extends State<_CloneDialog> {
  final _url = TextEditingController();
  late final _dir = TextEditingController(
      text: widget.settings.lastCloneDir ??
          p.join(Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '', 'Projects'));
  final _folder = TextEditingController();
  bool _folderEdited = false;
  bool _running = false;
  final List<String> _log = [];
  String? _error;

  void _onUrl(String url) {
    if (_folderEdited) return;
    var name = url.trim().split(RegExp(r'[/\\:]')).lastWhere((s) => s.isNotEmpty, orElse: () => '');
    if (name.endsWith('.git')) name = name.substring(0, name.length - 4);
    _folder.text = name;
  }

  Future<void> _clone() async {
    final url = _url.text.trim();
    final parent = _dir.text.trim();
    final folder = _folder.text.trim();
    if (url.isEmpty || parent.isEmpty || folder.isEmpty) {
      setState(() => _error = 'Fill in all fields');
      return;
    }
    if (Directory(p.join(parent, folder)).existsSync() &&
        Directory(p.join(parent, folder)).listSync().isNotEmpty) {
      setState(() => _error = 'Directory ${p.join(parent, folder)} already exists and is not empty');
      return;
    }
    setState(() {
      _running = true;
      _error = null;
      _log.clear();
    });
    try {
      await Directory(parent).create(recursive: true);
      await GitRepository.clone(url, parent, folder, onConsole: (e) {
        if (mounted) setState(() => _log.add(e.text));
      });
      widget.settings.lastCloneDir = parent;
      await widget.settings.save();
      if (mounted) Navigator.pop(context, p.normalize(p.join(parent, folder)));
    } on GitException catch (e) {
      if (mounted) {
        setState(() {
          _running = false;
          _error = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _running = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppDialog(
      title: 'Get from Version Control',
      width: 620,
      onSubmit: _running ? null : _clone,
      actions: [
        OutlinedButton(
          onPressed: _running ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _running ? null : _clone, child: const Text('Clone')),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _url,
            autofocus: true,
            enabled: !_running,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(labelText: 'URL', hintText: 'https://github.com/user/repo.git'),
            onChanged: _onUrl,
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _dir,
                enabled: !_running,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(labelText: 'Parent directory'),
              ),
            ),
            const SizedBox(width: 6),
            ToolButton(
              icon: Icons.folder_open,
              tooltip: 'Browse…',
              onPressed: _running
                  ? null
                  : () async {
                      final d = await FilePicker.getDirectoryPath(dialogTitle: 'Clone into');
                      if (d != null) _dir.text = d;
                    },
            ),
          ]),
          const SizedBox(height: 10),
          TextField(
            controller: _folder,
            enabled: !_running,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(labelText: 'Folder name'),
            onChanged: (_) => _folderEdited = true,
          ),
          if (_running || _log.isNotEmpty) ...[
            const SizedBox(height: 12),
            if (_running) const LinearProgressIndicator(minHeight: 2),
            Container(
              height: 110,
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.all(6),
              color: AppColors.background,
              child: ListView(
                reverse: true,
                children: [
                  for (final l in _log.reversed.take(50))
                    Text(l, style: monoStyle(size: 11.5, color: AppColors.textDim)),
                ],
              ),
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: const TextStyle(fontSize: 12.5, color: AppColors.error)),
            ),
        ],
      ),
    );
  }
}
