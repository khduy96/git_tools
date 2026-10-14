import 'package:flutter/material.dart';

import '../../git/models.dart';
import '../../state/repo_controller.dart';
import '../common.dart';
import 'basic_dialogs.dart';

Future<void> showStashDialog(BuildContext context, RepoController ctrl) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _StashDialog(ctrl: ctrl),
  );
}

class _StashDialog extends StatefulWidget {
  const _StashDialog({required this.ctrl});

  final RepoController ctrl;

  @override
  State<_StashDialog> createState() => _StashDialogState();
}

class _StashDialogState extends State<_StashDialog> {
  final _msg = TextEditingController();
  bool _untracked = false;
  bool _keepIndex = false;

  Future<void> _stash() async {
    Navigator.pop(context);
    await widget.ctrl.run(
      'Stash changes',
      () => widget.ctrl.repo.stash(
        message: _msg.text,
        includeUntracked: _untracked,
        keepIndex: _keepIndex,
      ),
      success: 'Local changes stashed',
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.ctrl.status.value;
    return AppDialog(
      title: 'Stash',
      onSubmit: _stash,
      actions: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _stash, child: const Text('Create Stash')),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Current branch: ${s.branch ?? 'detached HEAD'}',
              style: const TextStyle(fontSize: 13, color: AppColors.textDim)),
          const SizedBox(height: 10),
          TextField(
            controller: _msg,
            autofocus: true,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(labelText: 'Message'),
            onSubmitted: (_) => _stash(),
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _untracked,
            title: const Text('Include unversioned files', style: TextStyle(fontSize: 13)),
            onChanged: (v) => setState(() => _untracked = v ?? false),
          ),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _keepIndex,
            title: const Text('Keep index', style: TextStyle(fontSize: 13)),
            onChanged: (v) => setState(() => _keepIndex = v ?? false),
          ),
        ],
      ),
    );
  }
}

/// Bottom tool window tab listing stashes (Unstash in Android Studio).
class StashesPanel extends StatefulWidget {
  const StashesPanel({super.key, required this.controller});

  final RepoController controller;

  @override
  State<StashesPanel> createState() => _StashesPanelState();
}

class _StashesPanelState extends State<StashesPanel> {
  RepoController get ctrl => widget.controller;
  Stash? _selected;
  List<FileChange>? _files;
  bool _restoreIndex = false;

  Future<void> _select(Stash s) async {
    setState(() {
      _selected = s;
      _files = null;
    });
    final files = await ctrl.repo.stashFiles(s);
    if (mounted && _selected == s) setState(() => _files = files);
  }

  Future<void> _apply(Stash s, {required bool pop}) async {
    await ctrl.run(pop ? 'Pop ${s.ref}' : 'Apply ${s.ref}',
        () => ctrl.repo.stashApply(s, pop: pop, index: _restoreIndex),
        success: pop ? 'Stash popped' : 'Stash applied');
    if (pop) setState(() => _selected = null);
  }

  Future<void> _drop(Stash s) async {
    final ok = await showConfirm(context,
        title: 'Drop Stash',
        message: 'Drop ${s.ref} "${s.message}"?',
        confirmLabel: 'Drop',
        destructive: true);
    if (ok) {
      await ctrl.run('Drop ${s.ref}', () => ctrl.repo.stashDrop(s));
      setState(() => _selected = null);
    }
  }

  Future<void> _branch(Stash s) async {
    final name = await showInput(context,
        title: 'Unstash as Branch',
        label: 'New branch name:',
        validator: (v) => validateRefName(v,
            existing: ctrl.branches.value.where((b) => !b.isRemote).map((b) => b.name)));
    if (name == null) return;
    await ctrl.run('Create branch from stash', () => ctrl.repo.stashBranch(s, name.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Stash>>(
      valueListenable: ctrl.stashes,
      builder: (context, stashes, _) {
        final sel = _selected == null
            ? null
            : stashes.where((s) => s.hash == _selected!.hash).firstOrNull;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    height: 30,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Row(children: [
                      ToolButton(
                        icon: Icons.add_box_outlined,
                        tooltip: 'Stash Changes…',
                        onPressed: ctrl.status.value.changes.isEmpty
                            ? null
                            : () => showStashDialog(context, ctrl),
                      ),
                      ToolButton(
                        icon: Icons.unarchive_outlined,
                        tooltip: 'Pop (apply and drop)',
                        onPressed: sel == null ? null : () => _apply(sel, pop: true),
                      ),
                      ToolButton(
                        icon: Icons.download_done,
                        tooltip: 'Apply',
                        onPressed: sel == null ? null : () => _apply(sel, pop: false),
                      ),
                      ToolButton(
                        icon: Icons.call_split,
                        tooltip: 'Unstash as Branch…',
                        onPressed: sel == null ? null : () => _branch(sel),
                      ),
                      ToolButton(
                        icon: Icons.delete_outline,
                        tooltip: 'Drop',
                        onPressed: sel == null ? null : () => _drop(sel),
                      ),
                      ToolButton(
                        icon: Icons.clear_all,
                        tooltip: 'Clear All Stashes',
                        onPressed: stashes.isEmpty
                            ? null
                            : () async {
                                final ok = await showConfirm(context,
                                    title: 'Clear Stashes',
                                    message: 'Remove all ${stashes.length} stashes? This cannot be undone.',
                                    confirmLabel: 'Clear',
                                    destructive: true);
                                if (ok) await ctrl.run('Clear stashes', ctrl.repo.stashClear);
                              },
                      ),
                      const Spacer(),
                      Transform.scale(
                        scale: 0.8,
                        child: Checkbox(
                          value: _restoreIndex,
                          onChanged: (v) => setState(() => _restoreIndex = v ?? false),
                        ),
                      ),
                      const Text('Reinstate index', style: TextStyle(fontSize: 12, color: AppColors.textDim)),
                    ]),
                  ),
                  const Divider(),
                  Expanded(
                    child: stashes.isEmpty
                        ? const EmptyHint('No stashes', icon: Icons.inventory_2_outlined)
                        : ListView.builder(
                            itemCount: stashes.length,
                            itemBuilder: (context, i) {
                              final s = stashes[i];
                              return HoverRow(
                                height: 26,
                                selected: sel?.hash == s.hash,
                                onTap: () => _select(s),
                                onDoubleTap: () => _apply(s, pop: false),
                                onSecondaryTapDown: (d) async {
                                  _select(s);
                                  final r = await showContextMenu<String>(context, d.globalPosition, [
                                    menuItem('pop', 'Pop', icon: Icons.unarchive_outlined),
                                    menuItem('apply', 'Apply', icon: Icons.download_done),
                                    menuItem('branch', 'Unstash as Branch…', icon: Icons.call_split),
                                    const PopupMenuDivider(height: 8),
                                    menuItem('drop', 'Drop', icon: Icons.delete_outline),
                                  ]);
                                  switch (r) {
                                    case 'pop':
                                      _apply(s, pop: true);
                                    case 'apply':
                                      _apply(s, pop: false);
                                    case 'branch':
                                      _branch(s);
                                    case 'drop':
                                      _drop(s);
                                  }
                                },
                                child: Row(children: [
                                  const Icon(Icons.inventory_2_outlined, size: 14, color: AppColors.textDim),
                                  const SizedBox(width: 8),
                                  Text(s.ref, style: monoStyle(size: 12, color: AppColors.textMuted)),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(s.message,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 13)),
                                  ),
                                  Text(formatDate(s.time),
                                      style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
                                ]),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              flex: 2,
              child: sel == null
                  ? const EmptyHint('Select a stash to see its files')
                  : _files == null
                      ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                      : ListView(
                          children: [
                            for (final f in _files!)
                              HoverRow(
                                onDoubleTap: () => ctrl.showCommitDiff(
                                  f,
                                  f.type == ChangeType.untracked ? '${sel.hash}^3' : sel.hash,
                                  f.type == ChangeType.untracked ? null : '${sel.hash}^1',
                                  titleSuffix: '(${sel.ref})',
                                ),
                                child: Row(children: [
                                  Icon(fileIcon(f.fileName), size: 14, color: changeColor(f.type)),
                                  const SizedBox(width: 6),
                                  Text(f.fileName, style: TextStyle(fontSize: 13, color: changeColor(f.type))),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(f.directory,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
                                  ),
                                ]),
                              ),
                          ],
                        ),
            ),
          ],
        );
      },
    );
  }
}
