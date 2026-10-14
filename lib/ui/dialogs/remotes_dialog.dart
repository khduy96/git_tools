import 'package:flutter/material.dart';

import '../../git/models.dart';
import '../../state/repo_controller.dart';
import '../common.dart';
import 'basic_dialogs.dart';

/// Git ▸ Manage Remotes.
Future<void> showRemotesDialog(BuildContext context, RepoController ctrl) =>
    showDialog<void>(context: context, builder: (_) => _RemotesDialog(ctrl: ctrl));

class _RemotesDialog extends StatefulWidget {
  const _RemotesDialog({required this.ctrl});

  final RepoController ctrl;

  @override
  State<_RemotesDialog> createState() => _RemotesDialogState();
}

class _RemotesDialogState extends State<_RemotesDialog> {
  RepoController get ctrl => widget.ctrl;
  String? _selected;

  Future<(String, String)?> _edit({Remote? remote}) {
    final name = TextEditingController(text: remote?.name ?? (ctrl.remotes.value.isEmpty ? 'origin' : ''));
    final url = TextEditingController(text: remote?.url ?? '');
    return showDialog<(String, String)>(
      context: context,
      builder: (ctx) => AppDialog(
        title: remote == null ? 'Define Remote' : 'Edit Remote',
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (name.text.trim().isEmpty || url.text.trim().isEmpty) return;
              Navigator.pop(ctx, (name.text.trim(), url.text.trim()));
            },
            child: const Text('OK'),
          ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              enabled: remote == null,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: url,
              autofocus: true,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(labelText: 'URL'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Remote>>(
      valueListenable: ctrl.remotes,
      builder: (context, remotes, _) {
        final sel = remotes.where((r) => r.name == _selected).firstOrNull;
        return AppDialog(
          title: 'Git Remotes',
          width: 620,
          height: 340,
          actions: [
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          ],
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.border),
              color: AppColors.background,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  color: AppColors.panelAlt,
                  child: Row(children: [
                    ToolButton(
                      icon: Icons.add,
                      tooltip: 'Add',
                      onPressed: () async {
                        final r = await _edit();
                        if (r != null) await ctrl.run('Add remote', () => ctrl.repo.addRemote(r.$1, r.$2));
                      },
                    ),
                    ToolButton(
                      icon: Icons.remove,
                      tooltip: 'Remove',
                      onPressed: sel == null
                          ? null
                          : () async {
                              final ok = await showConfirm(context,
                                  title: 'Remove Remote',
                                  message: 'Remove remote ${sel.name}?',
                                  confirmLabel: 'Remove',
                                  destructive: true);
                              if (ok) await ctrl.run('Remove remote', () => ctrl.repo.removeRemote(sel.name));
                            },
                    ),
                    ToolButton(
                      icon: Icons.edit_outlined,
                      tooltip: 'Edit',
                      onPressed: sel == null
                          ? null
                          : () async {
                              final r = await _edit(remote: sel);
                              if (r != null) await ctrl.run('Edit remote', () => ctrl.repo.setRemoteUrl(sel.name, r.$2));
                            },
                    ),
                  ]),
                ),
                Expanded(
                  child: remotes.isEmpty
                      ? const EmptyHint('No remotes')
                      : ListView(
                          children: [
                            for (final r in remotes)
                              HoverRow(
                                selected: r.name == _selected,
                                onTap: () => setState(() => _selected = r.name),
                                child: Row(children: [
                                  SizedBox(
                                    width: 120,
                                    child: Text(r.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                                  ),
                                  Expanded(
                                    child: Text(r.url,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 13, color: AppColors.textDim)),
                                  ),
                                ]),
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
