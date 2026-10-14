import 'package:flutter/material.dart';

import '../../git/models.dart';
import '../../state/repo_controller.dart';
import '../common.dart';
import 'basic_dialogs.dart';

Future<void> showRollbackDialog(
    BuildContext context, RepoController ctrl, List<FileChange> changes) async {
  if (changes.isEmpty) return;
  await showDialog<void>(
    context: context,
    builder: (_) => _RollbackDialog(ctrl: ctrl, changes: changes),
  );
}

class _RollbackDialog extends StatefulWidget {
  const _RollbackDialog({required this.ctrl, required this.changes});

  final RepoController ctrl;
  final List<FileChange> changes;

  @override
  State<_RollbackDialog> createState() => _RollbackDialogState();
}

class _RollbackDialogState extends State<_RollbackDialog> {
  late final Set<String> _checked = widget.changes.map((c) => c.path).toSet();
  bool _deleteAdded = false;

  @override
  Widget build(BuildContext context) {
    final hasAdded = widget.changes.any((c) => c.type == ChangeType.added);
    final selected = widget.changes.where((c) => _checked.contains(c.path)).toList();
    return AppDialog(
      title: 'Rollback Changes',
      width: 560,
      actions: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: selected.isEmpty
              ? null
              : () async {
                  Navigator.pop(context);
                  await widget.ctrl.run(
                    'Rollback',
                    () => widget.ctrl.repo.rollback(selected,
                        deleteAdded: _deleteAdded,
                        hasHead: widget.ctrl.status.value.hasCommits),
                    success: '${selected.length} file(s) rolled back',
                  );
                },
          child: const Text('Rollback'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            constraints: const BoxConstraints(maxHeight: 320),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.border),
              color: AppColors.background,
            ),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final c in widget.changes)
                  HoverRow(
                    onTap: () => setState(() =>
                        _checked.contains(c.path) ? _checked.remove(c.path) : _checked.add(c.path)),
                    child: Row(children: [
                      Transform.scale(
                        scale: 0.8,
                        child: Checkbox(
                          value: _checked.contains(c.path),
                          onChanged: (v) => setState(() =>
                              v == true ? _checked.add(c.path) : _checked.remove(c.path)),
                        ),
                      ),
                      Icon(fileIcon(c.fileName), size: 15, color: changeColor(c.type)),
                      const SizedBox(width: 6),
                      Text(c.fileName, style: TextStyle(fontSize: 13, color: changeColor(c.type))),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(c.directory,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
                      ),
                    ]),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text('${selected.length} of ${widget.changes.length} files selected',
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
          if (hasAdded)
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _deleteAdded,
              title: const Text('Delete local copies of added files', style: TextStyle(fontSize: 13)),
              onChanged: (v) => setState(() => _deleteAdded = v ?? false),
            ),
        ],
      ),
    );
  }
}
