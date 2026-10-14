import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../git/git_process.dart';
import '../git/git_repository.dart';
import '../git/models.dart';
import '../state/repo_controller.dart';
import 'common.dart';
import 'dialogs/basic_dialogs.dart';

void showInExplorer(String root, String relPath) {
  final full = p.normalize(p.join(root, relPath));
  if (Platform.isWindows) {
    Process.run('explorer.exe', ['/select,', full]);
  } else if (Platform.isMacOS) {
    Process.run('open', ['-R', full]);
  } else {
    Process.run('xdg-open', [p.dirname(full)]);
  }
}

/// Opens [url] in the default browser.
void openUrl(String url) {
  if (Platform.isWindows) {
    Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
  } else if (Platform.isMacOS) {
    Process.run('open', [url]);
  } else {
    Process.run('xdg-open', [url]);
  }
}

void openFolder(String path) {
  if (Platform.isWindows) {
    Process.run('explorer.exe', [p.normalize(path)]);
  } else if (Platform.isMacOS) {
    Process.run('open', [path]);
  } else {
    Process.run('xdg-open', [path]);
  }
}

void openTerminal(String path) {
  if (Platform.isWindows) {
    Process.start('cmd.exe', ['/c', 'start', 'cmd.exe', '/k', 'cd', '/d', p.normalize(path)],
        mode: ProcessStartMode.detached);
  } else if (Platform.isMacOS) {
    Process.run('open', ['-a', 'Terminal', path]);
  } else {
    Process.start('x-terminal-emulator', [], workingDirectory: path, mode: ProcessStartMode.detached);
  }
}

Future<void> deleteUntracked(
    BuildContext context, RepoController ctrl, List<FileChange> files) async {
  final ok = await showConfirm(
    context,
    title: 'Delete',
    message: files.length == 1
        ? 'Delete "${files.first.path}"?'
        : 'Delete ${files.length} unversioned files?',
    confirmLabel: 'Delete',
    destructive: true,
  );
  if (ok) {
    await ctrl.run('Delete files',
        () => ctrl.repo.deleteFiles(files.map((f) => f.path).toList()));
  }
}

// -----------------------------------------------------------------------------
// Branch actions
// -----------------------------------------------------------------------------

bool _overwritten(GitException e) =>
    e.stderr.contains('would be overwritten') ||
    e.stderr.contains('Please commit your changes or stash them');

/// Checkout that offers "Smart Checkout" (stash, checkout, unstash) when
/// local changes would be overwritten.
Future<void> smartCheckout(
  BuildContext context,
  RepoController ctrl,
  String label,
  Future<void> Function() checkout,
) async {
  ctrl.busy.value = label;
  try {
    await checkout();
    ctrl.notify(AppNotification('$label done'));
  } on GitException catch (e) {
    ctrl.busy.value = null;
    if (_overwritten(e) && context.mounted) {
      final smart = await showDialog<bool>(
        context: context,
        builder: (ctx) => AppDialog(
          title: 'Git Checkout Problem',
          width: 520,
          actions: [
            OutlinedButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Don\'t Checkout')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Smart Checkout')),
          ],
          child: Text(
            'Your local changes would be overwritten by checkout.\n\n'
            '${e.message}\n\n'
            'Smart Checkout will stash local changes, checkout, and then unstash them.',
            style: const TextStyle(fontSize: 13, height: 1.4),
          ),
        ),
      );
      if (smart == true) {
        await ctrl.run(label, () async {
          await ctrl.repo.stash(message: 'Uncommitted changes before checkout', includeUntracked: false);
          try {
            await checkout();
          } finally {
            await ctrl.repo.git.run(['stash', 'pop'], log: true);
          }
        }, success: '$label done (local changes restored)');
      }
      return;
    }
    ctrl.notify(AppNotification('$label failed', details: e.message, isError: true));
  } finally {
    ctrl.busy.value = null;
    await ctrl.refreshAll();
  }
}

Future<void> checkoutBranch(
    BuildContext context, RepoController ctrl, Branch b) async {
  if (b.isCurrent) return;
  if (!b.isRemote) {
    await smartCheckout(context, ctrl, 'Checkout ${b.name}',
        () => ctrl.repo.checkout(b.name));
    return;
  }
  // Remote branch: checkout existing tracking branch or create one.
  final local = ctrl.branches.value
      .where((x) => !x.isRemote && x.name == b.shortName)
      .firstOrNull;
  if (local != null) {
    await smartCheckout(context, ctrl, 'Checkout ${local.name}',
        () => ctrl.repo.checkout(local.name));
  } else {
    await smartCheckout(context, ctrl, 'Checkout ${b.name}',
        () => ctrl.repo.checkoutRemote(b));
  }
}

Future<void> newBranchDialog(
  BuildContext context,
  RepoController ctrl, {
  String? startPoint,
  String? startLabel,
}) async {
  final result = await showDialog<(String, bool, bool)>(
    context: context,
    builder: (_) => _NewBranchDialog(
      existing: ctrl.branches.value.where((b) => !b.isRemote).map((b) => b.name).toSet(),
      from: startLabel ?? startPoint,
    ),
  );
  if (result == null || !context.mounted) return;
  final (name, checkout, overwrite) = result;
  if (checkout) {
    await smartCheckout(context, ctrl, 'Create branch $name',
        () => ctrl.repo.createBranch(name, startPoint: startPoint, force: overwrite));
  } else {
    await ctrl.run('Create branch $name',
        () => ctrl.repo.createBranch(name, startPoint: startPoint, checkout: false, force: overwrite),
        success: 'Branch $name created');
  }
}

class _NewBranchDialog extends StatefulWidget {
  const _NewBranchDialog({required this.existing, this.from});

  final Set<String> existing;
  final String? from;

  @override
  State<_NewBranchDialog> createState() => _NewBranchDialogState();
}

class _NewBranchDialogState extends State<_NewBranchDialog> {
  final _name = TextEditingController();
  bool _checkout = true;
  bool _overwrite = false;
  String? _error;

  void _submit() {
    final n = _name.text.trim();
    final err = validateRefName(n, existing: _overwrite ? const [] : widget.existing);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, (n, _checkout, _overwrite));
  }

  @override
  Widget build(BuildContext context) {
    final exists = widget.existing.contains(_name.text.trim());
    return AppDialog(
      title: widget.from == null ? 'Create New Branch' : 'Create New Branch from ${widget.from}',
      onSubmit: _submit,
      actions: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('New branch name:', style: TextStyle(fontSize: 13, color: AppColors.textDim)),
          const SizedBox(height: 6),
          TextField(
            controller: _name,
            autofocus: true,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(errorText: _error),
            onChanged: (_) => setState(() => _error = null),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _checkout,
            title: const Text('Checkout branch', style: TextStyle(fontSize: 13)),
            onChanged: (v) => setState(() => _checkout = v ?? true),
          ),
          if (exists)
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _overwrite,
              title: const Text('Overwrite existing branch', style: TextStyle(fontSize: 13)),
              onChanged: (v) => setState(() {
                _overwrite = v ?? false;
                _error = null;
              }),
            ),
        ],
      ),
    );
  }
}

Future<void> renameBranchDialog(
    BuildContext context, RepoController ctrl, Branch b) async {
  final existing = ctrl.branches.value.where((x) => !x.isRemote).map((x) => x.name);
  final name = await showInput(
    context,
    title: 'Rename Branch ${b.name}',
    label: 'New name:',
    initial: b.name,
    confirmLabel: 'Rename',
    validator: (v) => v.trim() == b.name ? 'Enter a different name' : validateRefName(v, existing: existing),
  );
  if (name == null) return;
  await ctrl.run('Rename branch', () => ctrl.repo.renameBranch(b.name, name.trim()),
      success: 'Renamed ${b.name} to ${name.trim()}');
}

Future<void> deleteBranchAction(
    BuildContext context, RepoController ctrl, Branch b) async {
  if (b.isRemote) {
    final ok = await showConfirm(context,
        title: 'Delete Remote Branch',
        message: 'Delete remote branch ${b.name}?\nThis pushes the deletion to ${b.remoteName}.',
        confirmLabel: 'Delete',
        destructive: true);
    if (ok) {
      await ctrl.run('Delete ${b.name}', () => ctrl.repo.deleteRemoteBranch(b),
          success: 'Deleted remote branch ${b.name}');
    }
    return;
  }
  ctrl.busy.value = 'Delete ${b.name}';
  try {
    await ctrl.repo.deleteBranch(b.name);
    ctrl.notify(AppNotification('Deleted branch ${b.name}'));
  } on GitException catch (e) {
    ctrl.busy.value = null;
    if (e.stderr.contains('not fully merged') && context.mounted) {
      final force = await showConfirm(context,
          title: 'Branch Is Not Fully Merged',
          message: 'Branch ${b.name} is not fully merged.\nDeleting it may lose commits. Delete anyway?',
          confirmLabel: 'Delete',
          destructive: true);
      if (force) {
        await ctrl.run('Delete ${b.name}', () => ctrl.repo.deleteBranch(b.name, force: true),
            success: 'Deleted branch ${b.name}');
      }
    } else {
      ctrl.notify(AppNotification('Delete branch failed', details: e.message, isError: true));
    }
  } finally {
    ctrl.busy.value = null;
    await ctrl.refreshAll();
  }
}

String _current(RepoController ctrl) =>
    ctrl.status.value.branch ?? 'HEAD';

Future<void> mergeIntoCurrent(
    BuildContext context, RepoController ctrl, String ref) async {
  await ctrl.run('Merge $ref into ${_current(ctrl)}', () => ctrl.repo.merge(ref),
      success: 'Merged $ref into ${_current(ctrl)}');
  _maybeShowConflicts(ctrl);
}

Future<void> rebaseCurrentOnto(
    BuildContext context, RepoController ctrl, String ref) async {
  await ctrl.run('Rebase ${_current(ctrl)} onto $ref', () => ctrl.repo.rebase(ref),
      success: 'Rebased ${_current(ctrl)} onto $ref');
  _maybeShowConflicts(ctrl);
}

Future<void> checkoutAndRebase(
    BuildContext context, RepoController ctrl, Branch b) async {
  final cur = _current(ctrl);
  await ctrl.run('Checkout ${b.name} and rebase onto $cur',
      () => ctrl.repo.rebase(cur, branch: b.name),
      success: 'Rebased ${b.name} onto $cur');
  _maybeShowConflicts(ctrl);
}

void _maybeShowConflicts(RepoController ctrl) {
  if (ctrl.status.value.conflicts.isNotEmpty) {
    ctrl.notify(AppNotification(
      'Conflicts need to be resolved',
      details: '${ctrl.status.value.conflicts.length} file(s) have conflicts. '
          'Open the Commit panel and click "Resolve".',
      isError: true,
    ));
  }
}

// -----------------------------------------------------------------------------
// Commit actions
// -----------------------------------------------------------------------------

Future<void> resetDialog(
    BuildContext context, RepoController ctrl, Commit c) async {
  final mode = await showDialog<ResetMode>(
    context: context,
    builder: (_) => _ResetDialog(
      branch: _current(ctrl),
      commit: c,
    ),
  );
  if (mode == null) return;
  await ctrl.run('Reset to ${c.shortHash}', () => ctrl.repo.reset(c.hash, mode),
      success: 'Reset ${_current(ctrl)} to ${c.shortHash} (${mode.name})');
}

class _ResetDialog extends StatefulWidget {
  const _ResetDialog({required this.branch, required this.commit});

  final String branch;
  final Commit commit;

  @override
  State<_ResetDialog> createState() => _ResetDialogState();
}

class _ResetDialogState extends State<_ResetDialog> {
  ResetMode _mode = ResetMode.mixed;

  static const _desc = {
    ResetMode.soft: 'Files won\'t change, differences will be staged for commit.',
    ResetMode.mixed: 'Files won\'t change, differences won\'t be staged.',
    ResetMode.hard: 'Files will be reverted to the state of the selected commit.\nWarning: any local changes will be lost.',
    ResetMode.keep: 'Files will be reverted to the state of the selected commit, but local changes will be kept intact.',
  };

  @override
  Widget build(BuildContext context) {
    return AppDialog(
      title: 'Git Reset',
      width: 520,
      actions: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          style: _mode == ResetMode.hard ? FilledButton.styleFrom(backgroundColor: AppColors.error) : null,
          onPressed: () => Navigator.pop(context, _mode),
          child: const Text('Reset'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(children: [
              const TextSpan(text: 'This will reset the current branch head '),
              TextSpan(text: widget.branch, style: const TextStyle(fontWeight: FontWeight.w600)),
              const TextSpan(text: ' to the selected commit '),
              TextSpan(text: widget.commit.shortHash, style: const TextStyle(fontWeight: FontWeight.w600)),
              const TextSpan(text: ', and will change the working tree and the index according to the selected mode:'),
            ]),
            style: const TextStyle(fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 10),
          RadioGroup<ResetMode>(
            groupValue: _mode,
            onChanged: (v) => setState(() => _mode = v!),
            child: Column(
              children: [
                for (final m in ResetMode.values)
                  RadioListTile<ResetMode>(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: m,
                    title: Text(m.name[0].toUpperCase() + m.name.substring(1),
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    subtitle: Text(_desc[m]!,
                        style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> newTagDialog(
    BuildContext context, RepoController ctrl, Commit c) async {
  final existing = ctrl.tags.value.map((t) => t.name).toSet();
  final result = await showDialog<(String, String)>(
    context: context,
    builder: (ctx) {
      final name = TextEditingController();
      final msg = TextEditingController();
      String? error;
      return StatefulBuilder(builder: (ctx, setLocal) {
        void submit() {
          final n = name.text.trim();
          var err = validateRefName(n);
          if (err == null && existing.contains(n)) err = 'Tag already exists';
          if (err != null) {
            setLocal(() => error = err);
            return;
          }
          Navigator.pop(ctx, (n, msg.text));
        }

        return AppDialog(
          title: 'Tag Commit ${c.shortHash}',
          onSubmit: submit,
          actions: [
            OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: submit, child: const Text('Create Tag')),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(labelText: 'Tag name', errorText: error),
                onSubmitted: (_) => submit(),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: msg,
                minLines: 3,
                maxLines: 6,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                    labelText: 'Message (optional, creates an annotated tag)'),
              ),
            ],
          ),
        );
      });
    },
  );
  if (result == null) return;
  await ctrl.run('Create tag ${result.$1}',
      () => ctrl.repo.createTag(result.$1, c.hash, message: result.$2),
      success: 'Created tag ${result.$1}');
}

Future<void> editHeadMessage(BuildContext context, RepoController ctrl) async {
  final current = await ctrl.repo.lastCommitMessage();
  if (!context.mounted) return;
  final msg = await showInput(context,
      title: 'Edit Commit Message',
      label: 'Commit message:',
      initial: current,
      multiline: true,
      validator: (v) => v.trim().isEmpty ? 'Message cannot be empty' : null);
  if (msg == null || msg.trim() == current.trim()) return;
  await ctrl.run('Edit commit message', () => ctrl.repo.rewordHead(msg.trim()),
      success: 'Commit message updated');
}

Future<void> undoCommit(BuildContext context, RepoController ctrl) async {
  final ok = await showConfirm(context,
      title: 'Undo Commit',
      message: 'Undo the last commit? Its changes will be kept in the working tree.',
      confirmLabel: 'Undo Commit');
  if (ok) {
    await ctrl.run('Undo commit', ctrl.repo.undoLastCommit,
        success: 'Commit undone, changes moved back to the Changes list');
  }
}

Future<void> dropCommitAction(
    BuildContext context, RepoController ctrl, Commit c) async {
  final ok = await showConfirm(context,
      title: 'Drop Commit',
      message: 'Drop commit ${c.shortHash} "${c.subject}" from ${_current(ctrl)}?\n'
          'This rewrites history of the current branch.',
      confirmLabel: 'Drop',
      destructive: true);
  if (ok) {
    await ctrl.run('Drop commit', () => ctrl.repo.dropCommit(c),
        success: 'Dropped commit ${c.shortHash}');
  }
}

Future<void> cherryPickAction(RepoController ctrl, List<Commit> commits) async {
  // Apply oldest first.
  final ordered = commits.reversed.toList();
  await ctrl.run(
    ordered.length == 1 ? 'Cherry-pick ${ordered.first.shortHash}' : 'Cherry-pick ${ordered.length} commits',
    () async {
      for (final c in ordered) {
        await ctrl.repo.cherryPick(c);
      }
    },
    success: 'Cherry-picked ${ordered.length} commit(s)',
  );
  _maybeShowConflicts(ctrl);
}

Future<void> revertAction(RepoController ctrl, List<Commit> commits) async {
  await ctrl.run(
    commits.length == 1 ? 'Revert ${commits.first.shortHash}' : 'Revert ${commits.length} commits',
    () async {
      for (final c in commits) {
        await ctrl.repo.revert(c);
      }
    },
    success: 'Reverted ${commits.length} commit(s)',
  );
  _maybeShowConflicts(ctrl);
}
