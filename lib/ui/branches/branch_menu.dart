import 'package:flutter/material.dart';

import '../../git/models.dart';
import '../../state/repo_controller.dart';
import '../actions.dart';
import '../common.dart';
import '../dialogs/basic_dialogs.dart';
import '../dialogs/push_dialog.dart';
import 'compare_dialog.dart';

/// Branch actions menu (same entries as the Android Studio branch popup).
Future<void> showBranchMenu(
  BuildContext context,
  RepoController ctrl,
  Branch b,
  Offset position,
) async {
  final action = await pickBranchAction(context, ctrl, b, position);
  if (action != null && context.mounted) {
    await runBranchAction(context, ctrl, b, action);
  }
}

Future<String?> pickBranchAction(
  BuildContext context,
  RepoController ctrl,
  Branch b,
  Offset position,
) {
  final cur = ctrl.status.value.branch;
  final curLabel = cur ?? 'HEAD';
  final isCurrent = b.isCurrent;
  String q(String s) => s.length > 30 ? '\'${s.substring(0, 28)}…\'' : '\'$s\'';
  return showContextMenu<String>(context, position, [
    menuItem('checkout', 'Checkout', icon: Icons.login, enabled: !isCurrent),
    menuItem('new', 'New Branch from ${q(b.name)}…', icon: Icons.add),
    if (!isCurrent && !b.isRemote)
      menuItem('checkoutRebase', 'Checkout and Rebase onto ${q(curLabel)}', icon: Icons.low_priority),
    const PopupMenuDivider(height: 8),
    menuItem('compare', 'Compare with ${q(curLabel)}', icon: Icons.compare_arrows, enabled: !isCurrent),
    menuItem('showLog', 'Show in Log', icon: Icons.manage_search),
    const PopupMenuDivider(height: 8),
    menuItem('rebase', 'Rebase ${q(curLabel)} onto ${q(b.name)}', icon: Icons.low_priority, enabled: !isCurrent && cur != null),
    menuItem('merge', 'Merge ${q(b.name)} into ${q(curLabel)}', icon: Icons.merge_type, enabled: !isCurrent),
    const PopupMenuDivider(height: 8),
    if (!b.isRemote && isCurrent) menuItem('push', 'Push…', icon: Icons.upload),
    if (!b.isRemote && b.upstream != null && !isCurrent)
      menuItem('update', 'Update (fast-forward from ${b.upstream})', icon: Icons.download),
    if (!b.isRemote) menuItem('rename', 'Rename…', icon: Icons.edit_outlined),
    menuItem('copy', 'Copy Branch Name', icon: Icons.copy),
    menuItem('delete', 'Delete', icon: Icons.delete_outline, enabled: !isCurrent, color: isCurrent ? null : AppColors.error),
  ]);
}

Future<void> runBranchAction(
  BuildContext context,
  RepoController ctrl,
  Branch b,
  String action,
) async {
  switch (action) {
    case 'checkout':
      await checkoutBranch(context, ctrl, b);
    case 'new':
      await newBranchDialog(context, ctrl, startPoint: b.name);
    case 'checkoutRebase':
      await checkoutAndRebase(context, ctrl, b);
    case 'compare':
      await showCompareDialog(context, ctrl, b.name);
    case 'showLog':
      ctrl.setLogFilter(ctrl.logFilter.value.copyWith(branch: () => b.name));
      ctrl.bottomTab.value = 0;
    case 'rebase':
      await rebaseCurrentOnto(context, ctrl, b.name);
    case 'merge':
      await mergeIntoCurrent(context, ctrl, b.name);
    case 'push':
      await showPushDialog(context, ctrl);
    case 'update':
      await ctrl.run('Update ${b.name}', () async {
        final up = b.upstream!;
        final slash = up.indexOf('/');
        // Fetch remote branch directly into the local branch (ff only).
        await ctrl.repo.git.run([
          'fetch',
          up.substring(0, slash),
          '${up.substring(slash + 1)}:${b.name}',
        ], log: true);
      }, success: '${b.name} updated');
    case 'rename':
      await renameBranchDialog(context, ctrl, b);
    case 'copy':
      copyToClipboard(context, b.name);
    case 'delete':
      await deleteBranchAction(context, ctrl, b);
  }
}

/// Context menu for a tag.
Future<void> showTagMenu(
  BuildContext context,
  RepoController ctrl,
  Tag t,
  Offset position,
) async {
  final r = await showContextMenu<String>(context, position, [
    menuItem('checkout', 'Checkout Tag', icon: Icons.login),
    menuItem('new', 'New Branch from \'${t.name}\'…', icon: Icons.add),
    menuItem('merge', 'Merge into Current', icon: Icons.merge_type),
    menuItem('push', 'Push Tag to ${ctrl.defaultRemote ?? 'remote'}', icon: Icons.upload, enabled: ctrl.defaultRemote != null),
    menuItem('copy', 'Copy Tag Name', icon: Icons.copy),
    const PopupMenuDivider(height: 8),
    menuItem('delete', 'Delete Tag', icon: Icons.delete_outline, color: AppColors.error),
  ]);
  if (r == null || !context.mounted) return;
  switch (r) {
    case 'checkout':
      await smartCheckout(context, ctrl, 'Checkout ${t.name}', () => ctrl.repo.checkout('refs/tags/${t.name}'));
    case 'new':
      await newBranchDialog(context, ctrl, startPoint: 'refs/tags/${t.name}', startLabel: t.name);
    case 'merge':
      await mergeIntoCurrent(context, ctrl, 'refs/tags/${t.name}');
    case 'push':
      await ctrl.run('Push tag ${t.name}', () => ctrl.repo.pushTag(ctrl.defaultRemote!, t.name),
          success: 'Pushed tag ${t.name}');
    case 'copy':
      copyToClipboard(context, t.name);
    case 'delete':
      final ok = await showConfirm(context,
          title: 'Delete Tag', message: 'Delete tag ${t.name} locally?', confirmLabel: 'Delete', destructive: true);
      if (ok) await ctrl.run('Delete tag', () => ctrl.repo.deleteTag(t.name), success: 'Deleted tag ${t.name}');
  }
}
