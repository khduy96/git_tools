import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../git/graph_layout.dart';
import '../../git/models.dart';
import '../../state/repo_controller.dart';
import '../actions.dart';
import '../branches/compare_dialog.dart';
import '../common.dart';
import 'graph_painter.dart';

const _rowHeight = 24.0;

class CommitTable extends StatefulWidget {
  const CommitTable({super.key, required this.controller});

  final RepoController controller;

  @override
  State<CommitTable> createState() => _CommitTableState();
}

class _CommitTableState extends State<CommitTable> {
  RepoController get ctrl => widget.controller;
  final _scroll = ScrollController();
  final _focus = FocusNode();
  late final _search = TextEditingController(text: ctrl.logFilter.value.text);
  Set<String> _multi = {};

  @override
  void dispose() {
    _scroll.dispose();
    _focus.dispose();
    _search.dispose();
    super.dispose();
  }

  List<(Commit, GraphRow?)> _visible() {
    final commits = ctrl.commits.value;
    final graph = ctrl.graph.value;
    final q = ctrl.logFilter.value.text.trim().toLowerCase();
    if (q.isEmpty) {
      return [
        for (var i = 0; i < commits.length; i++)
          (commits[i], i < graph.length ? graph[i] : null),
      ];
    }
    return [
      for (final c in commits)
        if (c.subject.toLowerCase().contains(q) ||
            c.hash.startsWith(q) ||
            c.authorName.toLowerCase().contains(q) ||
            c.authorEmail.toLowerCase().contains(q) ||
            c.refs.any((r) => r.name.toLowerCase().contains(q)))
          (c, null),
    ];
  }

  void _select(Commit c, List<(Commit, GraphRow?)> rows) {
    final keys = HardwareKeyboard.instance;
    setState(() {
      if (keys.isControlPressed) {
        _multi = {..._multi};
        _multi.contains(c.hash) ? _multi.remove(c.hash) : _multi.add(c.hash);
      } else if (keys.isShiftPressed && ctrl.selectedCommit.value != null) {
        final hashes = rows.map((r) => r.$1.hash).toList();
        final a = hashes.indexOf(ctrl.selectedCommit.value!.hash), b = hashes.indexOf(c.hash);
        if (a >= 0 && b >= 0) {
          _multi = hashes.sublist(a < b ? a : b, (a < b ? b : a) + 1).toSet();
        }
        return;
      } else {
        _multi = {c.hash};
      }
    });
    ctrl.selectedCommit.value = c;
  }

  void _move(List<(Commit, GraphRow?)> rows, int delta) {
    if (rows.isEmpty) return;
    final cur = ctrl.selectedCommit.value;
    var i = cur == null ? -1 : rows.indexWhere((r) => r.$1.hash == cur.hash);
    i = (i + delta).clamp(0, rows.length - 1);
    final c = rows[i].$1;
    setState(() => _multi = {c.hash});
    ctrl.selectedCommit.value = c;
    if (_scroll.hasClients) {
      final top = i * _rowHeight;
      final pos = _scroll.position;
      if (top < pos.pixels) {
        _scroll.jumpTo(top);
      } else if (top + _rowHeight > pos.pixels + pos.viewportDimension) {
        _scroll.jumpTo(top + _rowHeight - pos.viewportDimension);
      }
    }
  }

  List<Commit> _selectedCommits(List<(Commit, GraphRow?)> rows) =>
      [for (final r in rows) if (_multi.contains(r.$1.hash)) r.$1];

  Future<void> _contextMenu(Offset pos, Commit c, List<(Commit, GraphRow?)> rows) async {
    if (!_multi.contains(c.hash)) {
      setState(() => _multi = {c.hash});
      ctrl.selectedCommit.value = c;
    }
    final selected = _selectedCommits(rows);
    final single = selected.length == 1;
    final isHead = c.hash == ctrl.status.value.headHash;
    final r = await showContextMenu<String>(context, pos, [
      menuItem('copy', 'Copy Revision Number', icon: Icons.copy, shortcut: 'Ctrl+Alt+Shift+C'),
      const PopupMenuDivider(height: 8),
      menuItem('cherry', 'Cherry-Pick', icon: Icons.local_florist_outlined),
      menuItem('checkout', 'Checkout Revision \'${c.shortHash}\'', icon: Icons.login, enabled: single),
      menuItem('compare', 'Compare with Local', icon: Icons.compare_arrows, enabled: single),
      const PopupMenuDivider(height: 8),
      menuItem('reset', 'Reset Current Branch to Here…', icon: Icons.restore, enabled: single),
      menuItem('revert', 'Revert Commit', icon: Icons.undo),
      menuItem('undo', 'Undo Commit…', icon: Icons.settings_backup_restore, enabled: single && isHead && c.parents.isNotEmpty),
      const PopupMenuDivider(height: 8),
      menuItem('reword', 'Edit Commit Message…', icon: Icons.edit_outlined, enabled: single && isHead),
      menuItem('drop', 'Drop Commit', icon: Icons.delete_outline, enabled: single && !c.isMerge && c.parents.isNotEmpty),
      const PopupMenuDivider(height: 8),
      menuItem('branch', 'New Branch…', icon: Icons.call_split, enabled: single),
      menuItem('tag', 'New Tag…', icon: Icons.sell_outlined, enabled: single),
    ]);
    if (r == null || !mounted) return;
    switch (r) {
      case 'copy':
        copyToClipboard(context, selected.map((x) => x.hash).join(' '));
      case 'cherry':
        await cherryPickAction(ctrl, selected);
      case 'checkout':
        await smartCheckout(context, ctrl, 'Checkout ${c.shortHash}', () => ctrl.repo.checkout(c.hash));
      case 'compare':
        await showCompareDialog(context, ctrl, c.hash);
      case 'reset':
        await resetDialog(context, ctrl, c);
      case 'revert':
        await revertAction(ctrl, selected);
      case 'undo':
        await undoCommit(context, ctrl);
      case 'reword':
        await editHeadMessage(context, ctrl);
      case 'drop':
        await dropCommitAction(context, ctrl, c);
      case 'branch':
        await newBranchDialog(context, ctrl, startPoint: c.hash, startLabel: c.shortHash);
      case 'tag':
        await newTagDialog(context, ctrl, c);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _filterBar(),
          const Divider(),
          Expanded(
            child: ListenableBuilder(
              listenable: Listenable.merge([
                ctrl.commits,
                ctrl.graph,
                ctrl.logFilter,
                ctrl.selectedCommit,
                ctrl.status,
              ]),
              builder: (context, _) {
                final rows = _visible();
                if (rows.isEmpty) {
                  return ctrl.logLoading.value
                      ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                      : const EmptyHint('No commits', icon: Icons.history);
                }
                final textFilter = ctrl.logFilter.value.text.trim().isNotEmpty;
                final head = ctrl.status.value.headHash;
                final sel = ctrl.selectedCommit.value?.hash;
                return CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(rows, 1),
                    const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(rows, -1),
                    const SingleActivator(LogicalKeyboardKey.pageDown): () => _move(rows, 20),
                    const SingleActivator(LogicalKeyboardKey.pageUp): () => _move(rows, -20),
                    const SingleActivator(LogicalKeyboardKey.keyC, control: true, alt: true, shift: true): () {
                      final c = ctrl.selectedCommit.value;
                      if (c != null) copyToClipboard(context, c.hash);
                    },
                  },
                  child: Focus(
                    focusNode: _focus,
                    child: Scrollbar(
                      controller: _scroll,
                      child: ListView.builder(
                        controller: _scroll,
                        itemExtent: _rowHeight,
                        itemCount: rows.length,
                        itemBuilder: (context, i) {
                          final (c, g) = rows[i];
                          return _commitRow(
                            c,
                            textFilter ? null : g,
                            isHead: c.hash == head,
                            selected: c.hash == sel || _multi.contains(c.hash),
                            rows: rows,
                          );
                        },
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterBar() {
    return Container(
      height: 34,
      color: AppColors.panel,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: ValueListenableBuilder<LogFilter>(
        valueListenable: ctrl.logFilter,
        builder: (context, f, _) => Row(
          children: [
            SizedBox(
              width: 240,
              height: 26,
              child: TextField(
                controller: _search,
                style: const TextStyle(fontSize: 12.5),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search, size: 15),
                  prefixIconConstraints: BoxConstraints(minWidth: 28),
                  hintText: 'Text or hash',
                  contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                ),
                onChanged: (v) => ctrl.setLogFilter(f.copyWith(text: v)),
              ),
            ),
            const SizedBox(width: 8),
            _FilterChip(
              label: 'Branch: ${f.branch ?? 'All'}',
              active: f.branch != null,
              onClear: () => ctrl.setLogFilter(f.copyWith(branch: () => null)),
              onTap: (pos) async {
                final names = ['HEAD', ...ctrl.branches.value.map((b) => b.name)];
                final r = await showContextMenu<String>(context, pos, [
                  menuItem('__all__', 'All branches'),
                  const PopupMenuDivider(height: 8),
                  for (final n in names) menuItem(n, n),
                ]);
                if (r != null) ctrl.setLogFilter(f.copyWith(branch: () => r == '__all__' ? null : r));
              },
            ),
            if (f.path != null) ...[
              const SizedBox(width: 6),
              _FilterChip(
                label: 'Path: ${f.path}',
                active: true,
                onClear: () => ctrl.setLogFilter(f.copyWith(path: () => null)),
              ),
            ],
            const Spacer(),
            ValueListenableBuilder<bool>(
              valueListenable: ctrl.logLoading,
              builder: (_, loading, _) => loading
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5))
                  : const SizedBox(),
            ),
            const SizedBox(width: 6),
            ValueListenableBuilder<List<Commit>>(
              valueListenable: ctrl.commits,
              builder: (_, c, _) => Text('${c.length} commits',
                  style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
            ),
            ToolButton(
              icon: Icons.refresh,
              tooltip: 'Refresh',
              onPressed: () => ctrl.refreshAll(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _commitRow(Commit c, GraphRow? g,
      {required bool isHead, required bool selected, required List<(Commit, GraphRow?)> rows}) {
    return HoverRow(
      selected: selected,
      height: _rowHeight,
      padding: const EdgeInsets.only(left: 2, right: 8),
      onTap: () {
        _focus.requestFocus();
        _select(c, rows);
      },
      onSecondaryTapDown: (d) => _contextMenu(d.globalPosition, c, rows),
      child: Row(
        children: [
          if (g != null)
            CustomPaint(
              size: Size(graphWidth(g), _rowHeight),
              painter: GraphRowPainter(g, isHead: isHead),
            )
          else
            const SizedBox(width: 10),
          for (final r in c.refs) RefChip(r),
          Expanded(
            child: Text(
              c.subject,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isHead ? FontWeight.w600 : null,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 140,
            child: Text(c.authorName,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, color: AppColors.textDim)),
          ),
          SizedBox(
            width: 130,
            child: Text(formatDate(c.authorTime),
                style: const TextStyle(fontSize: 12.5, color: AppColors.textDim)),
          ),
          SizedBox(
            width: 68,
            child: Text(c.shortHash, style: monoStyle(size: 12, color: AppColors.textMuted)),
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.active,
    this.onTap,
    this.onClear,
  });

  final String label;
  final bool active;
  final void Function(Offset)? onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: onTap == null ? null : (d) => onTap!(d.globalPosition),
      child: Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: active ? AppColors.selection : null,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: active ? AppColors.accent : AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: Text(label, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
            ),
            if (onTap != null) const Icon(Icons.arrow_drop_down, size: 16, color: AppColors.textDim),
            if (active && onClear != null)
              InkWell(
                onTap: onClear,
                child: const Padding(
                  padding: EdgeInsets.only(left: 2),
                  child: Icon(Icons.close, size: 13, color: AppColors.textDim),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
