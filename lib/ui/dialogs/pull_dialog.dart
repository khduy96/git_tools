import 'package:flutter/material.dart';

import '../../state/app_settings.dart';
import '../../state/repo_controller.dart';
import '../common.dart';
import 'basic_dialogs.dart';

enum PullMode { merge, rebase, ffOnly }

/// "Update Project" / "Pull" dialog.
Future<void> showPullDialog(
    BuildContext context, RepoController ctrl, AppSettings settings) async {
  final s = ctrl.status.value;
  if (s.detached) {
    ctrl.notify(AppNotification('Cannot pull into detached HEAD',
        details: 'Checkout a branch first.', isError: true));
    return;
  }
  if (ctrl.remotes.value.isEmpty) {
    ctrl.notify(AppNotification('No remotes configured', isError: true));
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (_) => _PullDialog(ctrl: ctrl, settings: settings),
  );
}

class _PullDialog extends StatefulWidget {
  const _PullDialog({required this.ctrl, required this.settings});

  final RepoController ctrl;
  final AppSettings settings;

  @override
  State<_PullDialog> createState() => _PullDialogState();
}

class _PullDialogState extends State<_PullDialog> {
  RepoController get ctrl => widget.ctrl;

  late String _remote;
  String? _branch;
  late PullMode _mode =
      widget.settings.pullRebase ? PullMode.rebase : PullMode.merge;

  @override
  void initState() {
    super.initState();
    _remote = ctrl.defaultRemote!;
    final up = ctrl.status.value.upstream;
    if (up != null && up.startsWith('$_remote/')) {
      _branch = up.substring(_remote.length + 1);
    } else {
      _branch = _remoteBranches.contains(ctrl.status.value.branch)
          ? ctrl.status.value.branch
          : _remoteBranches.firstOrNull;
    }
  }

  List<String> get _remoteBranches => ctrl.branches.value
      .where((b) => b.isRemote && b.remoteName == _remote)
      .map((b) => b.shortName)
      .toList();

  Future<void> _pull() async {
    final branch = _branch;
    if (branch == null) return;
    Navigator.pop(context);
    widget.settings.pullRebase = _mode == PullMode.rebase;
    widget.settings.save();
    await ctrl.run(
      'Update ${ctrl.status.value.branch}',
      () => ctrl.repo.pull(
        remote: _remote,
        branch: branch,
        rebase: _mode == PullMode.rebase,
        ffOnly: _mode == PullMode.ffOnly,
      ),
      success: 'Updated from $_remote/$branch',
    );
    if (ctrl.status.value.conflicts.isNotEmpty) {
      ctrl.notify(AppNotification('Update finished with conflicts',
          details: 'Resolve the conflicts in the Commit panel.', isError: true));
    }
  }

  @override
  Widget build(BuildContext context) {
    final branches = _remoteBranches;
    return AppDialog(
      title: 'Update Project · Pull to ${ctrl.status.value.branch}',
      width: 520,
      onSubmit: _pull,
      actions: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _branch == null ? null : _pull, child: const Text('Pull')),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(width: 70, child: Text('Remote:', style: TextStyle(fontSize: 13, color: AppColors.textDim))),
              DropdownButton<String>(
                value: _remote,
                isDense: true,
                style: const TextStyle(fontSize: 13, color: AppColors.text),
                dropdownColor: AppColors.panel,
                items: [
                  for (final r in ctrl.remotes.value)
                    DropdownMenuItem(value: r.name, child: Text('${r.name}  (${r.url})', overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => setState(() {
                  _remote = v!;
                  _branch = _remoteBranches.firstOrNull;
                }),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const SizedBox(width: 70, child: Text('Branch:', style: TextStyle(fontSize: 13, color: AppColors.textDim))),
              if (branches.isEmpty)
                const Text('No remote branches (fetch first)', style: TextStyle(fontSize: 13, color: AppColors.textMuted))
              else
                DropdownButton<String>(
                  value: _branch,
                  isDense: true,
                  style: const TextStyle(fontSize: 13, color: AppColors.text),
                  dropdownColor: AppColors.panel,
                  items: [
                    for (final b in branches) DropdownMenuItem(value: b, child: Text(b)),
                  ],
                  onChanged: (v) => setState(() => _branch = v),
                ),
            ],
          ),
          const SizedBox(height: 14),
          const Text('Update type:', style: TextStyle(fontSize: 13, color: AppColors.textDim)),
          RadioGroup<PullMode>(
            groupValue: _mode,
            onChanged: (v) => setState(() => _mode = v!),
            child: const Column(
              children: [
                RadioListTile<PullMode>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: PullMode.merge,
                  title: Text('Merge', style: TextStyle(fontSize: 13)),
                  subtitle: Text('Merge incoming changes into the current branch',
                      style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
                ),
                RadioListTile<PullMode>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: PullMode.rebase,
                  title: Text('Rebase', style: TextStyle(fontSize: 13)),
                  subtitle: Text('Rebase the current branch on top of incoming changes',
                      style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
                ),
                RadioListTile<PullMode>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: PullMode.ffOnly,
                  title: Text('Fast-forward only', style: TextStyle(fontSize: 13)),
                  subtitle: Text('Fail if the update cannot be fast-forwarded',
                      style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
