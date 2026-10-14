import 'package:flutter/material.dart';

import '../../git/models.dart';
import '../../state/repo_controller.dart';
import '../common.dart';
import 'branch_menu.dart';

class BranchPopupActions {
  const BranchPopupActions({
    required this.update,
    required this.commit,
    required this.push,
    required this.newBranch,
    required this.checkoutRevision,
  });

  final VoidCallback update;
  final VoidCallback commit;
  final VoidCallback push;
  final VoidCallback newBranch;
  final VoidCallback checkoutRevision;
}

/// Android Studio style "Git Branches" popup shown under the branch widget.
Future<void> showBranchesPopup(
  BuildContext context,
  RepoController ctrl,
  Offset anchor,
  BranchPopupActions actions,
) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Branches',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 80),
    pageBuilder: (popupContext, _, _) => Stack(
      children: [
        Positioned(
          left: anchor.dx,
          top: anchor.dy,
          child: _BranchesPopup(
            ctrl: ctrl,
            outerContext: context,
            actions: actions,
          ),
        ),
      ],
    ),
  );
}

class _BranchesPopup extends StatefulWidget {
  const _BranchesPopup({
    required this.ctrl,
    required this.outerContext,
    required this.actions,
  });

  final RepoController ctrl;
  final BuildContext outerContext;
  final BranchPopupActions actions;

  @override
  State<_BranchesPopup> createState() => _BranchesPopupState();
}

class _BranchesPopupState extends State<_BranchesPopup> {
  final _search = TextEditingController();
  final Set<String> _collapsed = {};

  RepoController get ctrl => widget.ctrl;

  void _action(VoidCallback cb) {
    Navigator.pop(context);
    cb();
  }

  Future<void> _branchTap(Branch b, Offset pos) async {
    final action = await pickBranchAction(context, ctrl, b, pos);
    if (action == null || !mounted) return;
    Navigator.pop(context);
    final outer = widget.outerContext;
    if (outer.mounted) await runBranchAction(outer, ctrl, b, action);
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().toLowerCase();
    final all = ctrl.branches.value;
    bool match(Branch b) => q.isEmpty || b.name.toLowerCase().contains(q);
    final local = all.where((b) => !b.isRemote && match(b)).toList()
      ..sort((a, b) {
        if (a.isCurrent != b.isCurrent) return a.isCurrent ? -1 : 1;
        if (a.isFavorite != b.isFavorite) return a.isFavorite ? -1 : 1;
        return a.name.compareTo(b.name);
      });
    final remote = all.where((b) => b.isRemote && match(b)).toList()
      ..sort((a, b) {
        if (a.isFavorite != b.isFavorite) return a.isFavorite ? -1 : 1;
        return a.name.compareTo(b.name);
      });

    return Material(
      color: AppColors.panel,
      elevation: 12,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 380,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: TextField(
                controller: _search,
                autofocus: true,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search, size: 16),
                  prefixIconConstraints: BoxConstraints(minWidth: 30),
                  hintText: 'Search for branches and actions',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  if (q.isEmpty) ...[
                    _actionRow(Icons.download, 'Update Project…', 'Ctrl+T', () => _action(widget.actions.update)),
                    _actionRow(Icons.check, 'Commit…', 'Ctrl+K', () => _action(widget.actions.commit)),
                    _actionRow(Icons.upload, 'Push…', 'Ctrl+Shift+K', () => _action(widget.actions.push)),
                    const Divider(height: 9),
                    _actionRow(Icons.add, 'New Branch…', null, () => _action(widget.actions.newBranch)),
                    _actionRow(Icons.sell_outlined, 'Checkout Tag or Revision…', null,
                        () => _action(widget.actions.checkoutRevision)),
                    const Divider(height: 9),
                  ],
                  _section('local', 'Local', local),
                  _section('remote', 'Remote', remote),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionRow(IconData icon, String label, String? shortcut, VoidCallback onTap) {
    return HoverRow(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      onTap: onTap,
      child: Row(children: [
        Icon(icon, size: 15, color: AppColors.textDim),
        const SizedBox(width: 10),
        Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
        if (shortcut != null)
          Text(shortcut, style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
      ]),
    );
  }

  Widget _section(String key, String title, List<Branch> branches) {
    final collapsed = _collapsed.contains(key);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HoverRow(
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          onTap: () => setState(() => collapsed ? _collapsed.remove(key) : _collapsed.add(key)),
          child: Row(children: [
            Icon(collapsed ? Icons.chevron_right : Icons.expand_more, size: 16, color: AppColors.textDim),
            const SizedBox(width: 4),
            Text(title, style: const TextStyle(fontSize: 12, color: AppColors.textMuted, fontWeight: FontWeight.w600)),
          ]),
        ),
        if (!collapsed)
          for (final b in branches)
            Builder(builder: (rowContext) {
              return HoverRow(
                height: 28,
                padding: const EdgeInsets.only(left: 28, right: 10),
                onTap: () {
                  final box = rowContext.findRenderObject() as RenderBox;
                  _branchTap(b, box.localToGlobal(Offset(box.size.width - 8, 0)));
                },
                child: Row(children: [
                  Icon(
                    b.isCurrent ? Icons.sell : (b.isFavorite ? Icons.star : Icons.call_split),
                    size: 14,
                    color: b.isCurrent
                        ? AppColors.headRef
                        : b.isFavorite
                            ? AppColors.warning
                            : AppColors.textDim,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(b.name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: b.isCurrent ? FontWeight.w600 : null,
                        )),
                  ),
                  if (b.ahead > 0)
                    Text('↑${b.ahead} ', style: const TextStyle(fontSize: 12, color: AppColors.added)),
                  if (b.behind > 0)
                    Text('↓${b.behind} ', style: const TextStyle(fontSize: 12, color: AppColors.modified)),
                  if (b.upstream != null && !b.isRemote)
                    Flexible(
                      child: Text(b.upstream!,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
                    ),
                  const Icon(Icons.chevron_right, size: 16, color: AppColors.textMuted),
                ]),
              );
            }),
      ],
    );
  }
}
