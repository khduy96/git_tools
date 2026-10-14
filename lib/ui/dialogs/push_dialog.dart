import 'package:flutter/material.dart';

import '../../git/models.dart';
import '../../state/repo_controller.dart';
import '../common.dart';
import 'basic_dialogs.dart';

Future<void> showPushDialog(BuildContext context, RepoController ctrl) async {
  final s = ctrl.status.value;
  if (s.detached) {
    ctrl.notify(AppNotification('Cannot push from detached HEAD',
        details: 'Checkout a branch first.', isError: true));
    return;
  }
  if (ctrl.remotes.value.isEmpty) {
    ctrl.notify(AppNotification('No remotes configured',
        details: 'Add a remote in Git ▸ Manage Remotes.', isError: true));
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (_) => _PushDialog(ctrl: ctrl),
  );
}

class _PushDialog extends StatefulWidget {
  const _PushDialog({required this.ctrl});

  final RepoController ctrl;

  @override
  State<_PushDialog> createState() => _PushDialogState();
}

class _PushDialogState extends State<_PushDialog> {
  RepoController get ctrl => widget.ctrl;

  late String _remote;
  late final TextEditingController _target;
  bool _force = false;
  bool _tags = false;
  bool _newBranch = false;
  List<Commit>? _commits;
  Commit? _selected;
  List<FileChange>? _files;
  late final String _branch = ctrl.status.value.branch!;

  @override
  void initState() {
    super.initState();
    final up = ctrl.status.value.upstream;
    _remote = ctrl.defaultRemote!;
    var target = _branch;
    if (up != null && up.startsWith('$_remote/')) {
      target = up.substring(_remote.length + 1);
    }
    _target = TextEditingController(text: target);
    _loadCommits();
  }

  @override
  void dispose() {
    _target.dispose();
    super.dispose();
  }

  Future<void> _loadCommits() async {
    final remoteRef = 'refs/remotes/$_remote/${_target.text.trim()}';
    final exists = await ctrl.repo.refExists(remoteRef);
    final commits = await ctrl.repo.outgoingCommits(
      'HEAD',
      remoteRef: exists ? remoteRef : null,
      remote: _remote,
    );
    if (!mounted) return;
    setState(() {
      _newBranch = !exists;
      _commits = commits;
      _selected = commits.isEmpty ? null : commits.first;
    });
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    final c = _selected;
    if (c == null) {
      setState(() => _files = null);
      return;
    }
    final files = await ctrl.repo.changedFiles(c.parents.isEmpty ? null : c.parents.first, c.hash);
    if (mounted && _selected == c) setState(() => _files = files);
  }

  Future<void> _push() async {
    Navigator.pop(context);
    final target = _target.text.trim();
    final setUpstream = ctrl.status.value.upstream == null;
    await ctrl.run(
      _force ? 'Force push' : 'Push',
      () => ctrl.repo.push(
        remote: _remote,
        localRef: 'refs/heads/$_branch',
        remoteBranch: target,
        force: _force,
        setUpstream: setUpstream,
        tags: _tags,
      ),
      success: 'Pushed ${_commits?.length ?? 0} commit(s) to $_remote/$target',
    );
  }

  @override
  Widget build(BuildContext context) {
    final remotes = ctrl.remotes.value;
    return AppDialog(
      title: 'Push Commits to ${ctrl.name}',
      width: 820,
      height: 520,
      onSubmit: _push,
      leftActions: [
        Transform.scale(
          scale: 0.8,
          child: Checkbox(value: _force, onChanged: (v) => setState(() => _force = v ?? false)),
        ),
        const Text('Force push', style: TextStyle(fontSize: 13)),
        const SizedBox(width: 14),
        Transform.scale(
          scale: 0.8,
          child: Checkbox(value: _tags, onChanged: (v) => setState(() => _tags = v ?? false)),
        ),
        const Text('Push tags', style: TextStyle(fontSize: 13)),
      ],
      actions: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          style: _force ? FilledButton.styleFrom(backgroundColor: AppColors.error) : null,
          onPressed: _push,
          child: Text(_force ? 'Force Push' : 'Push'),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.call_split, size: 15, color: AppColors.localRef),
              const SizedBox(width: 6),
              Text(_branch, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Icon(Icons.arrow_forward, size: 15, color: AppColors.textDim),
              ),
              DropdownButton<String>(
                value: _remote,
                isDense: true,
                underline: const SizedBox(),
                style: const TextStyle(fontSize: 13, color: AppColors.text),
                dropdownColor: AppColors.panel,
                items: [
                  for (final r in remotes)
                    DropdownMenuItem(value: r.name, child: Text(r.name)),
                ],
                onChanged: (v) {
                  setState(() => _remote = v!);
                  _loadCommits();
                },
              ),
              const Text(' : ', style: TextStyle(fontSize: 13)),
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _target,
                  style: const TextStyle(fontSize: 13),
                  onSubmitted: (_) => _loadCommits(),
                  onEditingComplete: _loadCommits,
                ),
              ),
              if (_newBranch) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.added.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: const Text('New', style: TextStyle(fontSize: 11, color: AppColors.added)),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.border),
                color: AppColors.background,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 3, child: _commitList()),
                  const VerticalDivider(width: 1),
                  Expanded(flex: 2, child: _fileList()),
                ],
              ),
            ),
          ),
          if (_force)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Force push uses --force-with-lease and will overwrite remote history if it has not changed since your last fetch.',
                style: TextStyle(fontSize: 12, color: AppColors.warning),
              ),
            ),
        ],
      ),
    );
  }

  Widget _commitList() {
    final commits = _commits;
    if (commits == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (commits.isEmpty) {
      return const EmptyHint('No commits to push.\nEverything is up to date.');
    }
    return ListView.builder(
      itemCount: commits.length,
      itemBuilder: (context, i) {
        final c = commits[i];
        return HoverRow(
          height: 26,
          selected: c == _selected,
          onTap: () {
            setState(() => _selected = c);
            _loadFiles();
          },
          child: Row(
            children: [
              const Icon(Icons.commit, size: 14, color: AppColors.textDim),
              const SizedBox(width: 6),
              Expanded(
                child: Text(c.subject,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13)),
              ),
              Text(c.shortHash, style: monoStyle(size: 11.5, color: AppColors.textMuted)),
            ],
          ),
        );
      },
    );
  }

  Widget _fileList() {
    final files = _files;
    if (files == null) return const SizedBox();
    return ListView(
      children: [
        for (final f in files)
          SizedBox(
            height: 24,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(children: [
                Icon(fileIcon(f.fileName), size: 14, color: changeColor(f.type)),
                const SizedBox(width: 6),
                Text(f.fileName, style: TextStyle(fontSize: 12.5, color: changeColor(f.type))),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(f.directory,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
                ),
              ]),
            ),
          ),
      ],
    );
  }
}
