import 'package:flutter/material.dart';

import '../../git/models.dart';
import '../../state/repo_controller.dart';
import '../actions.dart';
import '../branches/branch_menu.dart';
import '../common.dart';

/// Left part of the Log tab: HEAD, local and remote branches, tags.
class BranchesTree extends StatefulWidget {
  const BranchesTree({super.key, required this.controller});

  final RepoController controller;

  @override
  State<BranchesTree> createState() => _BranchesTreeState();
}

class _BranchesTreeState extends State<BranchesTree> {
  RepoController get ctrl => widget.controller;
  final Set<String> _collapsed = {'tags'};
  final _search = TextEditingController();
  bool _searching = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _filter(String? ref) {
    ctrl.setLogFilter(ctrl.logFilter.value.copyWith(branch: () => ref, path: () => null));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.panel,
      child: ListenableBuilder(
        listenable: Listenable.merge([ctrl.branches, ctrl.tags, ctrl.logFilter, ctrl.status]),
        builder: (context, _) {
          final q = _search.text.trim().toLowerCase();
          bool match(String n) => q.isEmpty || n.toLowerCase().contains(q);
          final branches = ctrl.branches.value;
          final local = branches.where((b) => !b.isRemote && match(b.name)).toList();
          final remote = branches.where((b) => b.isRemote && match(b.name)).toList();
          final byRemote = <String, List<Branch>>{};
          for (final b in remote) {
            byRemote.putIfAbsent(b.remoteName, () => []).add(b);
          }
          final tags = ctrl.tags.value.where((t) => match(t.name)).toList();
          final filter = ctrl.logFilter.value.branch;
          final s = ctrl.status.value;

          final rows = <Widget>[
            _row(
              key: 'head',
              depth: 0,
              icon: Icons.my_location,
              iconColor: AppColors.headRef,
              label: s.detached
                  ? 'HEAD (detached at ${s.headHash?.substring(0, 8) ?? '?'})'
                  : 'HEAD (Current Branch)',
              selected: filter == 'HEAD',
              onTap: () => _filter(filter == 'HEAD' ? null : 'HEAD'),
            ),
            _group('local', 'Local', local.length),
            if (!_collapsed.contains('local'))
              for (final b in local) _branchRow(b, 1, filter),
            _group('remote', 'Remote', remote.length),
            if (!_collapsed.contains('remote'))
              for (final entry in byRemote.entries) ...[
                _group('remote:${entry.key}', entry.key, entry.value.length, depth: 1, icon: Icons.cloud_outlined),
                if (!_collapsed.contains('remote:${entry.key}'))
                  for (final b in entry.value) _branchRow(b, 2, filter),
              ],
            _group('tags', 'Tags', tags.length),
            if (!_collapsed.contains('tags'))
              for (final t in tags)
                Builder(builder: (rowCtx) {
                  return _row(
                    key: 'tag:${t.name}',
                    depth: 1,
                    icon: Icons.sell_outlined,
                    iconColor: AppColors.tagRef,
                    label: t.name,
                    selected: filter == 'refs/tags/${t.name}',
                    onTap: () => _filter('refs/tags/${t.name}'),
                    onSecondary: (pos) => showTagMenu(context, ctrl, t, pos),
                  );
                }),
          ];

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 30,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(children: [
                  ToolButton(
                    icon: Icons.add,
                    tooltip: 'New Branch…',
                    onPressed: () => newBranchDialog(context, ctrl),
                  ),
                  ToolButton(
                    icon: Icons.search,
                    tooltip: 'Search branches',
                    selected: _searching,
                    onPressed: () => setState(() {
                      _searching = !_searching;
                      if (!_searching) _search.clear();
                    }),
                  ),
                  ToolButton(
                    icon: Icons.download,
                    tooltip: 'Fetch All Remotes',
                    onPressed: () => ctrl.run('Fetch', () => ctrl.repo.fetch(), success: 'Fetched all remotes'),
                  ),
                  const Spacer(),
                  if (filter != null)
                    ToolButton(
                      icon: Icons.filter_alt_off_outlined,
                      tooltip: 'Show all branches',
                      onPressed: () => _filter(null),
                    ),
                ]),
              ),
              if (_searching)
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 0, 6, 4),
                  child: TextField(
                    controller: _search,
                    autofocus: true,
                    style: const TextStyle(fontSize: 12.5),
                    decoration: const InputDecoration(hintText: 'Filter branches'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              const Divider(),
              Expanded(child: ListView(children: rows)),
            ],
          );
        },
      ),
    );
  }

  Widget _group(String key, String label, int count, {int depth = 0, IconData? icon}) {
    final collapsed = _collapsed.contains(key);
    return HoverRow(
      padding: EdgeInsets.only(left: 4.0 + depth * 14),
      onTap: () => setState(() => collapsed ? _collapsed.remove(key) : _collapsed.add(key)),
      child: Row(children: [
        Icon(collapsed ? Icons.chevron_right : Icons.expand_more, size: 16, color: AppColors.textDim),
        const SizedBox(width: 2),
        Icon(icon ?? Icons.folder_outlined, size: 14, color: AppColors.textDim),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 13)),
        const SizedBox(width: 6),
        Text('$count', style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
      ]),
    );
  }

  Widget _branchRow(Branch b, int depth, String? filter) {
    return _row(
      key: b.name,
      depth: depth,
      icon: b.isCurrent ? Icons.sell : (b.isFavorite ? Icons.star : Icons.call_split),
      iconColor: b.isCurrent
          ? AppColors.headRef
          : b.isFavorite
              ? AppColors.warning
              : (b.isRemote ? AppColors.remoteRef : AppColors.localRef),
      label: b.isRemote ? b.shortName : b.name,
      bold: b.isCurrent,
      trailing: [
        if (b.ahead > 0) Text('↑${b.ahead}', style: const TextStyle(fontSize: 11.5, color: AppColors.added)),
        if (b.behind > 0) Text(' ↓${b.behind}', style: const TextStyle(fontSize: 11.5, color: AppColors.modified)),
        if (b.gone) const Text(' gone', style: TextStyle(fontSize: 11.5, color: AppColors.error)),
      ],
      selected: filter == b.name,
      onTap: () => _filter(b.name),
      onDoubleTap: () => checkoutBranch(context, ctrl, b),
      onSecondary: (pos) => showBranchMenu(context, ctrl, b, pos),
    );
  }

  Widget _row({
    required String key,
    required int depth,
    required IconData icon,
    required Color iconColor,
    required String label,
    bool selected = false,
    bool bold = false,
    List<Widget> trailing = const [],
    VoidCallback? onTap,
    VoidCallback? onDoubleTap,
    void Function(Offset)? onSecondary,
  }) {
    return HoverRow(
      selected: selected,
      padding: EdgeInsets.only(left: 22.0 + depth * 14, right: 6),
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      onSecondaryTapDown: onSecondary == null ? null : (d) => onSecondary(d.globalPosition),
      child: Row(children: [
        Icon(icon, size: 14, color: iconColor),
        const SizedBox(width: 6),
        Expanded(
          child: Text(label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, fontWeight: bold ? FontWeight.w600 : null)),
        ),
        ...trailing,
      ]),
    );
  }
}
