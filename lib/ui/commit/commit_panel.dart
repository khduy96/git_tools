import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../git/models.dart';
import '../../state/app_settings.dart';
import '../../state/repo_controller.dart';
import '../actions.dart';
import '../common.dart';
import '../conflicts/conflicts_dialog.dart';
import '../dialogs/ai_settings_dialog.dart';
import '../dialogs/push_dialog.dart';
import '../dialogs/rollback_dialog.dart';
import '../dialogs/stash_dialogs.dart';

class _Node {
  _Node.group(this.key, this.label, this.files, {this.checkable = true})
      : change = null,
        depth = 0,
        isGroup = true,
        isDir = false;

  _Node.dir(this.key, this.label, this.files, this.depth)
      : change = null,
        isGroup = false,
        isDir = true,
        checkable = true;

  _Node.file(this.key, FileChange c, this.depth, {this.checkable = true})
      : change = c,
        label = c.fileName,
        files = [c],
        isGroup = false,
        isDir = false;

  final String key;
  final String label;
  final FileChange? change;
  final List<FileChange> files;
  final int depth;
  final bool isGroup;
  final bool isDir;
  final bool checkable;
}

class CommitPanel extends StatefulWidget {
  const CommitPanel({
    super.key,
    required this.controller,
    required this.settings,
    this.messageFocus,
  });

  final AppSettings settings;

  final RepoController controller;
  final FocusNode? messageFocus;

  @override
  State<CommitPanel> createState() => _CommitPanelState();
}

class _CommitPanelState extends State<CommitPanel> {
  RepoController get ctrl => widget.controller;

  final Set<String> _collapsed = {};
  Set<String> _selected = {};
  String? _anchor;
  bool _groupByDir = false;
  bool _signOff = false;
  final _author = TextEditingController();
  final _listFocus = FocusNode();
  late final FocusNode _messageFocus = widget.messageFocus ?? FocusNode();

  @override
  void dispose() {
    _author.dispose();
    _listFocus.dispose();
    if (widget.messageFocus == null) _messageFocus.dispose();
    super.dispose();
  }

  List<_Node> _buildNodes(RepoStatus s) {
    final nodes = <_Node>[];
    void addFiles(String groupKey, List<FileChange> files, {bool checkable = true}) {
      if (_collapsed.contains(groupKey)) return;
      if (!_groupByDir) {
        for (final f in files) {
          nodes.add(_Node.file('$groupKey/${f.path}', f, 1, checkable: checkable));
        }
        return;
      }
      // Group by directory (one level per distinct directory path).
      final byDir = <String, List<FileChange>>{};
      for (final f in files) {
        byDir.putIfAbsent(f.directory, () => []).add(f);
      }
      final dirs = byDir.keys.toList()..sort();
      for (final d in dirs) {
        final dirFiles = byDir[d]!;
        if (d.isEmpty) {
          for (final f in dirFiles) {
            nodes.add(_Node.file('$groupKey/${f.path}', f, 1, checkable: checkable));
          }
          continue;
        }
        final key = '$groupKey/dir:$d';
        nodes.add(_Node.dir(key, d, dirFiles, 1));
        if (_collapsed.contains(key)) continue;
        for (final f in dirFiles) {
          nodes.add(_Node.file('$groupKey/${f.path}', f, 2, checkable: checkable));
        }
      }
    }

    final conflicts = s.conflicts;
    if (conflicts.isNotEmpty) {
      nodes.add(_Node.group('conflicts', 'Merge Conflicts', conflicts, checkable: false));
      addFiles('conflicts', conflicts, checkable: false);
    }
    final tracked = s.tracked;
    nodes.add(_Node.group('changes', 'Changes', tracked));
    addFiles('changes', tracked);
    final untracked = s.untracked;
    if (untracked.isNotEmpty) {
      nodes.add(_Node.group('unversioned', 'Unversioned Files', untracked));
      addFiles('unversioned', untracked);
    }
    return nodes;
  }

  List<FileChange> _selectedChanges(RepoStatus s) {
    final byPath = {for (final c in s.changes) c.path: c};
    return [
      for (final key in _selected)
        if (byPath[key] != null) byPath[key]!,
    ];
  }

  void _select(_Node n, List<_Node> all) {
    final c = n.change;
    if (c == null) return;
    final keys = HardwareKeyboard.instance;
    setState(() {
      if (keys.isControlPressed) {
        _selected = {..._selected};
        _selected.contains(c.path) ? _selected.remove(c.path) : _selected.add(c.path);
        _anchor = c.path;
      } else if (keys.isShiftPressed && _anchor != null) {
        final files = all.where((x) => x.change != null).map((x) => x.change!.path).toList();
        final a = files.indexOf(_anchor!), b = files.indexOf(c.path);
        if (a >= 0 && b >= 0) {
          _selected = files.sublist(a < b ? a : b, (a < b ? b : a) + 1).toSet();
        }
      } else {
        _selected = {c.path};
        _anchor = c.path;
      }
    });
    if (_selected.length == 1 && c.type != ChangeType.conflicted) {
      ctrl.showLocalDiff(c, preview: true);
    }
  }

  void _moveSelection(List<_Node> nodes, int delta) {
    final files = nodes.where((n) => n.change != null).toList();
    if (files.isEmpty) return;
    var i = files.indexWhere((n) => n.change!.path == _anchor);
    i = (i + delta).clamp(0, files.length - 1);
    setState(() {
      _anchor = files[i].change!.path;
      _selected = {_anchor!};
    });
  }

  void _openDiff(FileChange c) {
    if (c.type == ChangeType.conflicted) {
      showConflictsDialog(context, ctrl);
    } else {
      ctrl.showLocalDiff(c);
    }
  }

  Future<void> _contextMenu(Offset pos, List<FileChange> sel) async {
    if (sel.isEmpty) return;
    final allUntracked = sel.every((c) => c.type == ChangeType.untracked);
    final anyTracked = sel.any((c) => c.type != ChangeType.untracked && c.type != ChangeType.conflicted);
    final single = sel.length == 1 ? sel.first : null;
    final r = await showContextMenu<String>(context, pos, [
      menuItem('diff', 'Show Diff', icon: Icons.difference_outlined, shortcut: 'Ctrl+D'),
      if (sel.any((c) => c.type == ChangeType.conflicted))
        menuItem('resolve', 'Resolve Conflicts…', icon: Icons.merge_type),
      menuItem('lines', 'Select Lines to Commit…', icon: Icons.checklist,
          enabled: single != null && ctrl.canSelectLines(single) && ctrl.status.value.state == RepoState.normal),
      const PopupMenuDivider(height: 8),
      menuItem('rollback', 'Rollback…', icon: Icons.undo, enabled: anyTracked, shortcut: 'Ctrl+Alt+Z'),
      if (allUntracked) menuItem('delete', 'Delete', icon: Icons.delete_outline),
      if (allUntracked) menuItem('ignore', 'Add to .gitignore', icon: Icons.visibility_off_outlined),
      const PopupMenuDivider(height: 8),
      menuItem('history', 'Show History', icon: Icons.history, enabled: single != null && single.type != ChangeType.untracked),
      menuItem('blame', 'Annotate with Git Blame', icon: Icons.person_search_outlined,
          enabled: single != null && single.type != ChangeType.untracked && single.type != ChangeType.added && single.type != ChangeType.deleted),
      const PopupMenuDivider(height: 8),
      menuItem('copy', 'Copy Path', icon: Icons.copy),
      menuItem('explorer', 'Show in Explorer', icon: Icons.folder_open_outlined, enabled: single != null),
    ]);
    if (!mounted || r == null) return;
    switch (r) {
      case 'diff':
        _openDiff(sel.first);
      case 'lines':
        ctrl.openLineSelection(single!.path);
      case 'resolve':
        showConflictsDialog(context, ctrl);
      case 'rollback':
        showRollbackDialog(context, ctrl, sel.where((c) => c.type != ChangeType.untracked).toList());
      case 'delete':
        await deleteUntracked(context, ctrl, sel);
      case 'ignore':
        await ctrl.run('Add to .gitignore', () => ctrl.repo.addToGitignore(sel.map((c) => '/${c.path}').toList()));
      case 'history':
        ctrl.showHistory(single!.path);
      case 'blame':
        ctrl.openTab(BlameTab(single!.path));
      case 'copy':
        copyToClipboard(context, sel.map((c) => c.path).join('\n'));
      case 'explorer':
        showInExplorer(ctrl.root, single!.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.panel,
      child: ValueListenableBuilder<RepoStatus>(
        valueListenable: ctrl.status,
        builder: (context, s, _) {
          final nodes = _buildNodes(s);
          final sel = _selectedChanges(s);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PanelHeader(title: 'Commit', actions: [
                ToolButton(
                  icon: Icons.refresh,
                  tooltip: 'Refresh',
                  onPressed: () => ctrl.refreshAll(),
                ),
                ToolButton(
                  icon: Icons.undo,
                  tooltip: 'Rollback… (Ctrl+Alt+Z)',
                  onPressed: () {
                    final target = sel.isNotEmpty ? sel : ctrl.includedChanges;
                    final tracked = target.where((c) => c.type != ChangeType.untracked && c.type != ChangeType.conflicted).toList();
                    if (tracked.isNotEmpty) showRollbackDialog(context, ctrl, tracked);
                  },
                ),
                ToolButton(
                  icon: Icons.difference_outlined,
                  tooltip: 'Show Diff (Ctrl+D)',
                  onPressed: sel.isEmpty ? null : () => _openDiff(sel.first),
                ),
                ToolButton(
                  icon: Icons.inventory_2_outlined,
                  tooltip: 'Stash Changes…',
                  onPressed: s.changes.isEmpty ? null : () => showStashDialog(context, ctrl),
                ),
                ToolButton(
                  icon: _groupByDir ? Icons.account_tree_outlined : Icons.list,
                  tooltip: _groupByDir ? 'Group by: Directory' : 'Group by: None',
                  selected: _groupByDir,
                  onPressed: () => setState(() => _groupByDir = !_groupByDir),
                ),
                ToolButton(
                  icon: Icons.unfold_more,
                  tooltip: 'Expand All',
                  onPressed: () => setState(_collapsed.clear),
                ),
                ToolButton(
                  icon: Icons.unfold_less,
                  tooltip: 'Collapse All',
                  onPressed: () => setState(() {
                    _collapsed.addAll(nodes.where((n) => n.isGroup || n.isDir).map((n) => n.key));
                  }),
                ),
              ]),
              if (s.state != RepoState.normal) _StateBanner(controller: ctrl, status: s),
              Expanded(child: _tree(nodes, sel)),
              const Divider(),
              _commitArea(s),
            ],
          );
        },
      ),
    );
  }

  Widget _tree(List<_Node> nodes, List<FileChange> sel) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyD, control: true): () {
          if (sel.isNotEmpty) _openDiff(sel.first);
        },
        const SingleActivator(LogicalKeyboardKey.enter): () {
          if (sel.isNotEmpty) _openDiff(sel.first);
        },
        const SingleActivator(LogicalKeyboardKey.space): () {
          if (sel.isEmpty) return;
          final include = !sel.every((c) => ctrl.included.value.contains(c.path));
          ctrl.setIncluded(sel, include);
        },
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _moveSelection(nodes, 1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _moveSelection(nodes, -1),
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true, alt: true): () {
          final tracked = sel.where((c) => c.type != ChangeType.untracked && c.type != ChangeType.conflicted).toList();
          if (tracked.isNotEmpty) showRollbackDialog(context, ctrl, tracked);
        },
        const SingleActivator(LogicalKeyboardKey.keyA, control: true): () => setState(() {
              _selected = nodes.where((n) => n.change != null).map((n) => n.change!.path).toSet();
            }),
      },
      child: Focus(
        focusNode: _listFocus,
        child: ListenableBuilder(
          listenable: Listenable.merge([ctrl.included, ctrl.lineSelections]),
          builder: (context, _) {
            final included = ctrl.included.value;
            final s = ctrl.status.value;
            if (s.changes.isEmpty) {
              return Column(
                children: [
                  _nodeRow(nodes.first, included),
                  const Expanded(
                    child: EmptyHint('No changes', icon: Icons.check_circle_outline),
                  ),
                ],
              );
            }
            return ListView.builder(
              itemCount: nodes.length,
              itemExtent: 24,
              itemBuilder: (context, i) => _nodeRow(nodes[i], included, nodes: nodes),
            );
          },
        ),
      ),
    );
  }

  Widget _nodeRow(_Node n, Set<String> included, {List<_Node>? nodes}) {
    final c = n.change;
    final selected = c != null && _selected.contains(c.path);
    bool? checked;
    if (n.checkable) {
      final count = n.files.where((f) => included.contains(f.path)).length;
      checked = count == 0
          ? false
          : count == n.files.length
              ? true
              : null;
      if (n.files.isEmpty) checked = false;
      // Half-checked when only some lines of a file are committed.
      if (n.files.any((f) => ctrl.lineSelections.value.containsKey(f.path)) && checked == true) checked = null;
    }
    final lines = c == null ? null : ctrl.lineSelections.value[c.path];
    final collapsible = n.isGroup || n.isDir;
    final collapsed = _collapsed.contains(n.key);
    return HoverRow(
      selected: selected,
      padding: EdgeInsets.only(left: 4.0 + n.depth * 16),
      onTap: () {
        _listFocus.requestFocus();
        if (collapsible) {
          setState(() => collapsed ? _collapsed.remove(n.key) : _collapsed.add(n.key));
        } else if (nodes != null) {
          _select(n, nodes);
        }
      },
      onDoubleTap: c == null ? null : () => _openDiff(c),
      onSecondaryTapDown: (d) {
        if (c == null) return;
        if (!_selected.contains(c.path)) setState(() => _selected = {c.path});
        _contextMenu(d.globalPosition, _selectedChanges(ctrl.status.value));
      },
      child: Row(
        children: [
          SizedBox(
            width: 16,
            child: collapsible
                ? Icon(collapsed ? Icons.chevron_right : Icons.expand_more,
                    size: 16, color: AppColors.textDim)
                : null,
          ),
          if (n.checkable)
            SizedBox(
              width: 22,
              child: Transform.scale(
                scale: 0.8,
                child: Checkbox(
                  value: checked,
                  tristate: true,
                  onChanged: n.files.isEmpty
                      ? null
                      : (_) => ctrl.setIncluded(n.files, checked != true),
                ),
              ),
            )
          else
            const SizedBox(width: 4),
          const SizedBox(width: 4),
          if (n.isGroup) ...[
            Icon(
              n.key == 'conflicts'
                  ? Icons.warning_amber_rounded
                  : n.key == 'unversioned'
                      ? Icons.help_outline
                      : Icons.folder_special_outlined,
              size: 15,
              color: n.key == 'conflicts' ? AppColors.conflict : AppColors.textDim,
            ),
            const SizedBox(width: 6),
            Text(n.label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
            const SizedBox(width: 8),
            Text('${n.files.length} file${n.files.length == 1 ? '' : 's'}',
                style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
            if (n.key == 'conflicts') ...[
              const SizedBox(width: 10),
              InkWell(
                onTap: () => showConflictsDialog(context, ctrl),
                child: const Text('Resolve',
                    style: TextStyle(fontSize: 12.5, color: AppColors.accentHover)),
              ),
            ],
          ] else if (n.isDir) ...[
            const Icon(Icons.folder_outlined, size: 15, color: AppColors.textDim),
            const SizedBox(width: 6),
            Expanded(
              child: Text(n.label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, color: AppColors.textDim)),
            ),
          ] else ...[
            Icon(fileIcon(c!.fileName), size: 15, color: changeColor(c.type).withValues(alpha: 0.85)),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                c.fileName,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: changeColor(c.type),
                  decoration: c.type == ChangeType.deleted ? TextDecoration.lineThrough : null,
                  decorationColor: AppColors.deleted,
                ),
              ),
            ),
            if (lines != null) ...[
              const SizedBox(width: 6),
              Tooltip(
                message: 'Only some lines are committed. Click to change the selection.',
                child: InkWell(
                  onTap: () => ctrl.openLineSelection(c.path),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('${lines.selected}/${lines.total} lines',
                        style: const TextStyle(fontSize: 11, color: Colors.white)),
                  ),
                ),
              ),
            ],
            if (!_groupByDir || c.oldPath != null) ...[
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  c.oldPath != null
                      ? '← ${c.oldPath}'
                      : c.directory,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                ),
              ),
            ] else
              const Spacer(),
          ],
        ],
      ),
    );
  }

  Widget _commitArea(RepoStatus s) {
    final count = ctrl.included.value.length;
    final inMerge = s.state != RepoState.normal;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: ctrl.amend,
                builder: (context, amend, _) => InkWell(
                  onTap: s.hasCommits ? () => ctrl.toggleAmend(!amend) : null,
                  child: Row(children: [
                    Transform.scale(
                      scale: 0.8,
                      child: Checkbox(
                        value: amend,
                        onChanged: s.hasCommits ? (v) => ctrl.toggleAmend(v ?? false) : null,
                      ),
                    ),
                    const Text('Amend', style: TextStyle(fontSize: 13)),
                  ]),
                ),
              ),
              const Spacer(),
              ValueListenableBuilder<bool>(
                valueListenable: ctrl.generating,
                builder: (context, busy, _) => busy
                    ? Tooltip(
                        message: 'Stop generating',
                        child: InkWell(
                          onTap: ctrl.cancelGeneration,
                          borderRadius: BorderRadius.circular(4),
                          child: const SizedBox(
                            width: 26,
                            height: 26,
                            child: Stack(alignment: Alignment.center, children: [
                              SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 1.5)),
                              Icon(Icons.stop, size: 10, color: AppColors.textDim),
                            ]),
                          ),
                        ),
                      )
                    : ToolButton(
                        icon: Icons.auto_awesome,
                        tooltip: widget.settings.aiConfigured
                            ? 'Generate Commit Message (${widget.settings.aiModel})'
                            : 'Generate Commit Message (set up AI first)',
                        color: AppColors.accentHover,
                        onPressed: _generate,
                      ),
              ),
              PopupMenuButton<void>(
                tooltip: 'Commit Options',
                icon: const Icon(Icons.settings_outlined, size: 16, color: AppColors.textDim),
                padding: EdgeInsets.zero,
                itemBuilder: (_) => [
                  PopupMenuItem<void>(
                    enabled: false,
                    child: StatefulBuilder(
                      builder: (context, setLocal) => SizedBox(
                        width: 280,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Commit Options',
                                style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.text)),
                            const SizedBox(height: 8),
                            CheckboxListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
                              title: const Text('Sign-off commit', style: TextStyle(fontSize: 13, color: AppColors.text)),
                              value: _signOff,
                              onChanged: (v) {
                                setLocal(() => _signOff = v ?? false);
                                setState(() {});
                              },
                            ),
                            const SizedBox(height: 4),
                            TextField(
                              controller: _author,
                              style: const TextStyle(fontSize: 13, color: AppColors.text),
                              decoration: const InputDecoration(
                                labelText: 'Author (Name <email>)',
                              ),
                            ),
                            const SizedBox(height: 10),
                            TextButton.icon(
                              icon: const Icon(Icons.auto_awesome, size: 15),
                              label: const Text('AI Commit Message Settings…'),
                              onPressed: () {
                                Navigator.pop(context);
                                showAiSettingsDialog(this.context, widget.settings)
                                    .then((_) => setState(() {}));
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 4),
          CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.enter, control: true): _commit,
            },
            child: TextField(
              controller: ctrl.commitMessage,
              focusNode: _messageFocus,
              minLines: 4,
              maxLines: 8,
              style: const TextStyle(fontSize: 13, height: 1.35),
              decoration: InputDecoration(
                hintText: inMerge ? 'Merge commit message' : 'Commit Message',
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton(
                onPressed: _commit,
                child: ValueListenableBuilder<bool>(
                  valueListenable: ctrl.amend,
                  builder: (_, amend, _) => Text(amend ? 'Amend Commit' : 'Commit'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => _commit(push: true),
                child: const Text('Commit and Push…'),
              ),
              const Spacer(),
              Flexible(
                child: Text(
                  count == 0 ? '' : '$count selected',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _generate() async {
    if (!widget.settings.aiConfigured) {
      final saved = await showAiSettingsDialog(context, widget.settings);
      if (!mounted) return;
      setState(() {});
      if (!saved || !widget.settings.aiConfigured) return;
    }
    await ctrl.generateCommitMessage(widget.settings);
  }

  Future<void> _commit({bool push = false}) async {
    final ok = await ctrl.commit(
      signOff: _signOff,
      author: _author.text.trim().isEmpty ? null : _author.text.trim(),
    );
    if (ok && push && mounted) {
      await showPushDialog(context, ctrl);
    }
  }
}

class _StateBanner extends StatelessWidget {
  const _StateBanner({required this.controller, required this.status});

  final RepoController controller;
  final RepoStatus status;

  @override
  Widget build(BuildContext context) {
    final s = status.state;
    final label = switch (s) {
      RepoState.merging => 'Merging',
      RepoState.rebasing => 'Rebasing',
      RepoState.cherryPicking => 'Cherry-picking',
      RepoState.reverting => 'Reverting',
      RepoState.normal => '',
    };
    final conflicts = status.conflicts.length;
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.12),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.info_outline, size: 15, color: AppColors.warning),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                conflicts > 0
                    ? '$label in progress · $conflicts conflict${conflicts == 1 ? '' : 's'}'
                    : '$label in progress · all conflicts resolved',
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              if (conflicts > 0)
                _BannerButton('Resolve…', () => showConflictsDialog(context, controller)),
              if (conflicts == 0)
                _BannerButton('Continue', () => controller.run(
                      'Continue $label',
                      () => controller.repo.continueOperation(s),
                    )),
              if (s == RepoState.rebasing)
                _BannerButton('Skip Commit', () => controller.run(
                      'Skip commit',
                      () => controller.repo.skipRebaseCommit(),
                    )),
              _BannerButton('Abort', () => controller.run(
                    'Abort $label',
                    () => controller.repo.abortOperation(s),
                  )),
            ],
          ),
        ],
      ),
    );
  }
}

class _BannerButton extends StatelessWidget {
  const _BannerButton(this.label, this.onTap);

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 26,
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 26),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            textStyle: const TextStyle(fontSize: 12),
          ),
          onPressed: onTap,
          child: Text(label),
        ),
      );
}
