import 'dart:io';

import 'package:flutter/material.dart';

import 'git/git_repository.dart';
import 'state/app_settings.dart';
import 'state/repo_controller.dart';
import 'ui/common.dart';
import 'ui/welcome_page.dart';
import 'ui/workspace_page.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  String? gitVersion;
  try {
    final r = await Process.run('git', ['--version']);
    if (r.exitCode == 0) gitVersion = (r.stdout as String).trim();
  } catch (_) {}
  runApp(GitToolsApp(
    settings: settings,
    gitVersion: gitVersion,
    initialPath: args.isNotEmpty ? args.first : null,
  ));
}

class GitToolsApp extends StatefulWidget {
  const GitToolsApp({
    super.key,
    required this.settings,
    this.gitVersion,
    this.initialPath,
  });

  final AppSettings settings;
  final String? gitVersion;
  final String? initialPath;

  @override
  State<GitToolsApp> createState() => _GitToolsAppState();
}

class _GitToolsAppState extends State<GitToolsApp> {
  final _navKey = GlobalKey<NavigatorState>();
  RepoController? _ctrl;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    final path = widget.initialPath;
    if (path != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _open(path));
    }
  }

  Future<void> _open(String path) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final root = await GitRepository.findRoot(path);
      if (root == null) {
        _showError('Not a Git repository', path);
        return;
      }
      final ctrl = RepoController(root);
      await ctrl.open();
      _ctrl?.dispose();
      setState(() => _ctrl = ctrl);
      await widget.settings.addRecent(root);
    } catch (e) {
      _showError('Cannot open repository', '$e');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  void _close() {
    _ctrl?.dispose();
    setState(() => _ctrl = null);
  }

  Future<void> _pickAndOpen() async {
    final ctx = _navKey.currentContext;
    if (ctx == null) return;
    final root = await pickRepository(ctx);
    if (root != null) await _open(root);
  }

  Future<void> _cloneAndOpen() async {
    final ctx = _navKey.currentContext;
    if (ctx == null) return;
    final root = await showCloneDialog(ctx, widget.settings);
    if (root != null) await _open(root);
  }

  void _showError(String title, String details) {
    final ctx = _navKey.currentContext;
    if (ctx == null) return;
    showDialog<void>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 15)),
        content: Text(details, style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = _ctrl;
    Widget home;
    if (widget.gitVersion == null) {
      home = const Scaffold(
        body: EmptyHint(
          'Git was not found on PATH.\nInstall Git (https://git-scm.com) and restart the app.',
          icon: Icons.error_outline,
        ),
      );
    } else if (ctrl == null) {
      home = Stack(children: [
        WelcomePage(
          settings: widget.settings,
          gitVersion: widget.gitVersion,
          onOpen: _open,
        ),
        if (_opening)
          const ColoredBox(
            color: Color(0x88000000),
            child: Center(child: CircularProgressIndicator()),
          ),
      ]);
    } else {
      home = WorkspacePage(
        key: ValueKey(ctrl.root),
        controller: ctrl,
        settings: widget.settings,
        onOpenRepo: _pickAndOpen,
        onCloneRepo: _cloneAndOpen,
        onSwitchRepo: _open,
        onClose: _close,
      );
    }
    return MaterialApp(
      title: ctrl == null ? 'Git Tools' : '${ctrl.name} – Git Tools',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      navigatorKey: _navKey,
      home: home,
    );
  }
}
