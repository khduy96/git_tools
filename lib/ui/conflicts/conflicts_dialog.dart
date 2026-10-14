import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../git/conflict_parser.dart';
import '../../git/models.dart';
import '../../state/repo_controller.dart';
import '../common.dart';
import '../dialogs/basic_dialogs.dart';

(String, String) _sideTitles(RepoController ctrl) {
  final s = ctrl.status.value;
  if (s.state == RepoState.rebasing) {
    return ('Upstream (rebasing onto)', 'Your commit');
  }
  return ('Yours (${s.branch ?? 'HEAD'})', 'Theirs (incoming)');
}

String _sideStatus(String c) => switch (c) {
      'D' => 'Deleted',
      'A' => 'Added',
      _ => 'Modified',
    };

Future<void> showConflictsDialog(BuildContext context, RepoController ctrl) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _ConflictsDialog(ctrl: ctrl),
  );
}

class _ConflictsDialog extends StatefulWidget {
  const _ConflictsDialog({required this.ctrl});

  final RepoController ctrl;

  @override
  State<_ConflictsDialog> createState() => _ConflictsDialogState();
}

class _ConflictsDialogState extends State<_ConflictsDialog> {
  RepoController get ctrl => widget.ctrl;
  Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    ctrl.status.addListener(_onStatus);
    final first = ctrl.status.value.conflicts.firstOrNull;
    if (first != null) _selected = {first.path};
  }

  @override
  void dispose() {
    ctrl.status.removeListener(_onStatus);
    super.dispose();
  }

  void _onStatus() {
    if (!mounted) return;
    if (ctrl.status.value.conflicts.isEmpty) {
      Navigator.of(context).pop();
      ctrl.notify(AppNotification('All conflicts resolved'));
    } else {
      setState(() {});
    }
  }

  List<FileChange> get _sel =>
      ctrl.status.value.conflicts.where((c) => _selected.contains(c.path)).toList();

  Future<void> _accept(bool ours) async {
    final files = _sel;
    if (files.isEmpty) return;
    await ctrl.run(ours ? 'Accept yours' : 'Accept theirs', () async {
      for (final f in files) {
        await ctrl.repo.acceptSide(f, ours: ours);
      }
    });
  }

  Future<void> _merge() async {
    final f = _sel.firstOrNull;
    if (f == null) return;
    final code = f.conflictCode ?? 'UU';
    if (code.contains('D')) {
      ctrl.notify(AppNotification('Cannot merge this file',
          details: 'One side deleted the file. Use Accept Yours or Accept Theirs.',
          isError: true));
      return;
    }
    await showMergeTool(context, ctrl, f);
  }

  @override
  Widget build(BuildContext context) {
    final conflicts = ctrl.status.value.conflicts;
    final (yours, theirs) = _sideTitles(ctrl);
    return AppDialog(
      title: 'Conflicts',
      width: 760,
      height: 420,
      actions: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.border),
                color: AppColors.background,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    height: 26,
                    color: AppColors.panelAlt,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(children: [
                      const Expanded(flex: 3, child: Text('Name', style: TextStyle(fontSize: 12, color: AppColors.textDim))),
                      Expanded(flex: 2, child: Text(yours, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: AppColors.textDim))),
                      Expanded(flex: 2, child: Text(theirs, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: AppColors.textDim))),
                    ]),
                  ),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final c in conflicts)
                          HoverRow(
                            selected: _selected.contains(c.path),
                            onTap: () => setState(() => _selected = {c.path}),
                            onDoubleTap: () {
                              setState(() => _selected = {c.path});
                              _merge();
                            },
                            child: Row(children: [
                              Expanded(
                                flex: 3,
                                child: Row(children: [
                                  Icon(fileIcon(c.fileName), size: 14, color: AppColors.conflict),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(c.path,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 13, color: AppColors.conflict)),
                                  ),
                                ]),
                              ),
                              Expanded(
                                flex: 2,
                                child: Text(_sideStatus((c.conflictCode ?? 'UU')[0]),
                                    style: const TextStyle(fontSize: 12.5)),
                              ),
                              Expanded(
                                flex: 2,
                                child: Text(_sideStatus((c.conflictCode ?? 'UU')[1]),
                                    style: const TextStyle(fontSize: 12.5)),
                              ),
                            ]),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 150,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                OutlinedButton(onPressed: _sel.isEmpty ? null : () => _accept(true), child: const Text('Accept Yours')),
                const SizedBox(height: 8),
                OutlinedButton(onPressed: _sel.isEmpty ? null : () => _accept(false), child: const Text('Accept Theirs')),
                const SizedBox(height: 8),
                FilledButton(onPressed: _sel.isEmpty ? null : _merge, child: const Text('Merge…')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Three-way merge tool
// -----------------------------------------------------------------------------

Future<void> showMergeTool(BuildContext context, RepoController ctrl, FileChange f) async {
  final file = File(p.join(ctrl.root, f.path));
  String text = await file.exists() ? await file.readAsString() : '';
  if (!hasConflictMarkers(text)) {
    text = await ctrl.repo.mergeFromStages(f.path);
  }
  final eol = text.contains('\r\n') ? '\r\n' : '\n';
  final segments = parseConflicts(text);
  if (!context.mounted) return;
  if (!segments.any((s) => s is ConflictSegment)) {
    final ok = await showConfirm(context,
        title: 'No Conflict Markers',
        message: '${f.path} has no conflict markers. Mark it as resolved with its current content?',
        confirmLabel: 'Mark Resolved');
    if (ok) {
      await ctrl.run('Mark resolved', () => ctrl.repo.git.run(['add', '--', f.path], log: true));
    }
    return;
  }
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _MergeTool(ctrl: ctrl, file: f, segments: segments, eol: eol),
  );
}

class _MergeTool extends StatefulWidget {
  const _MergeTool({
    required this.ctrl,
    required this.file,
    required this.segments,
    required this.eol,
  });

  final RepoController ctrl;
  final FileChange file;
  final List<MergeSegment> segments;
  final String eol;

  @override
  State<_MergeTool> createState() => _MergeToolState();
}

class _MergeToolState extends State<_MergeTool> {
  final _scroll = ScrollController();
  final _keys = <int, GlobalKey>{};

  List<ConflictSegment> get _conflicts =>
      widget.segments.whereType<ConflictSegment>().toList();

  int get _unresolved => _conflicts.where((c) => !c.resolved).length;

  void _resolveAll(ConflictChoice choice) {
    setState(() {
      for (final c in _conflicts) {
        if (!c.resolved) c.choice = choice;
      }
    });
  }

  void _nextUnresolved() {
    for (var i = 0; i < widget.segments.length; i++) {
      final s = widget.segments[i];
      if (s is ConflictSegment && !s.resolved) {
        final ctx = _keys[i]?.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 200), alignment: 0.2);
        }
        return;
      }
    }
  }

  Future<void> _apply() async {
    final content = joinSegments(widget.segments, eol: widget.eol);
    Navigator.pop(context);
    await widget.ctrl.run('Resolve ${widget.file.fileName}',
        () => widget.ctrl.repo.markResolved(widget.file.path, content),
        success: '${widget.file.path} resolved');
  }

  Future<void> _edit(ConflictSegment c) async {
    final initial = (c.resolved ? c.result : [...c.ours, ...c.theirs]).join('\n');
    final v = await showInput(context,
        title: 'Edit Result', label: 'Merged text:', initial: initial, multiline: true);
    if (v == null) return;
    setState(() {
      c.custom = v.isEmpty ? const [] : v.replaceAll('\r\n', '\n').split('\n');
      c.choice = ConflictChoice.custom;
    });
  }

  @override
  Widget build(BuildContext context) {
    final (yours, theirs) = _sideTitles(widget.ctrl);
    final size = MediaQuery.sizeOf(context);
    final unresolved = _unresolved;
    return AppDialog(
      title: 'Merge Revisions for ${widget.file.path}',
      width: size.width * 0.92,
      height: size.height * 0.88,
      leftActions: [
        Text(
          unresolved == 0
              ? 'All changes have been processed.'
              : '$unresolved of ${_conflicts.length} conflict${_conflicts.length == 1 ? '' : 's'} unresolved',
          style: TextStyle(fontSize: 12.5, color: unresolved == 0 ? AppColors.success : AppColors.warning),
        ),
      ],
      actions: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        Tooltip(
          message: unresolved > 0 ? 'Resolve all conflicts first' : '',
          child: FilledButton(onPressed: unresolved > 0 ? null : _apply, child: const Text('Apply')),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.keyboard_double_arrow_right, size: 16),
              label: const Text('Accept Left'),
              onPressed: unresolved == 0 ? null : () => _resolveAll(ConflictChoice.ours),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.keyboard_double_arrow_left, size: 16),
              label: const Text('Accept Right'),
              onPressed: unresolved == 0 ? null : () => _resolveAll(ConflictChoice.theirs),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.arrow_downward, size: 16),
              label: const Text('Next Conflict'),
              onPressed: unresolved == 0 ? null : _nextUnresolved,
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _colTitle(yours, AppColors.diffModifiedMark)),
            Expanded(child: _colTitle('Result', AppColors.textDim)),
            Expanded(child: _colTitle(theirs, AppColors.diffInsertedMark)),
          ]),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.border),
                color: AppColors.background,
              ),
              child: Scrollbar(
                controller: _scroll,
                child: SingleChildScrollView(
                  controller: _scroll,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < widget.segments.length; i++)
                        _segment(i, widget.segments[i]),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _colTitle(String t, Color c) => Padding(
        padding: const EdgeInsets.only(bottom: 4, left: 4),
        child: Text(t, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c)),
      );

  Widget _lines(List<String> lines, {Color? bg}) {
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text(
          lines.isEmpty ? ' ' : lines.join('\n'),
          softWrap: false,
          style: monoStyle(size: 12.5),
        ),
      ),
    );
  }

  Widget _segment(int index, MergeSegment s) {
    switch (s) {
      case TextSegment(:final lines):
        final shown = lines.length > 10
            ? [...lines.take(4), '⋯ ${lines.length - 8} unchanged lines ⋯', ...lines.skip(lines.length - 4)]
            : lines;
        return Opacity(opacity: 0.7, child: _lines(shown));
      case ConflictSegment():
        final key = _keys.putIfAbsent(index, () => GlobalKey());
        return Container(
          key: key,
          margin: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            border: Border.symmetric(
              horizontal: BorderSide(color: s.resolved ? AppColors.border : AppColors.conflict.withValues(alpha: 0.6)),
            ),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _side(s, ours: true)),
                const VerticalDivider(width: 1),
                Expanded(child: _result(s)),
                const VerticalDivider(width: 1),
                Expanded(child: _side(s, ours: false)),
              ],
            ),
          ),
        );
    }
  }

  Widget _side(ConflictSegment s, {required bool ours}) {
    final lines = ours ? s.ours : s.theirs;
    final picked = s.choice == (ours ? ConflictChoice.ours : ConflictChoice.theirs);
    return Container(
      color: (ours ? AppColors.diffModifiedBg : AppColors.diffInsertedBg)
          .withValues(alpha: s.resolved && !picked ? 0.35 : 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisAlignment: ours ? MainAxisAlignment.end : MainAxisAlignment.start,
              children: [
                if (!ours) _acceptBtn(s, ours: false),
                Text(lines.isEmpty ? '(empty)' : '${lines.length} line${lines.length == 1 ? '' : 's'}',
                    style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
                if (ours) _acceptBtn(s, ours: true),
              ],
            ),
          ),
          _lines(lines),
        ],
      ),
    );
  }

  Widget _acceptBtn(ConflictSegment s, {required bool ours}) {
    return Tooltip(
      message: ours ? 'Accept left' : 'Accept right',
      child: InkWell(
        onTap: () => setState(() => s.choice = ours ? ConflictChoice.ours : ConflictChoice.theirs),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Icon(
            ours ? Icons.keyboard_double_arrow_right : Icons.keyboard_double_arrow_left,
            size: 16,
            color: AppColors.accentHover,
          ),
        ),
      ),
    );
  }

  Widget _result(ConflictSegment s) {
    Widget chip(String label, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(right: 4),
          child: InkWell(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(label, style: const TextStyle(fontSize: 11, color: AppColors.text)),
            ),
          ),
        );
    return Container(
      color: s.resolved ? null : AppColors.conflict.withValues(alpha: 0.08),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                if (!s.resolved) ...[
                  chip('Left + Right', () => setState(() => s.choice = ConflictChoice.oursThenTheirs)),
                  chip('Right + Left', () => setState(() => s.choice = ConflictChoice.theirsThenOurs)),
                  if (s.base != null) chip('Base', () => setState(() => s.choice = ConflictChoice.base)),
                  chip('Edit…', () => _edit(s)),
                ] else ...[
                  const Icon(Icons.check, size: 14, color: AppColors.success),
                  const SizedBox(width: 4),
                  chip('Edit…', () => _edit(s)),
                  chip('Undo', () => setState(() => s.choice = ConflictChoice.unresolved)),
                ],
              ]),
            ),
          ),
          if (s.resolved)
            _lines(s.result)
          else
            Padding(
              padding: const EdgeInsets.all(6),
              child: Text(
                s.base != null && s.base!.isNotEmpty ? 'Base:\n${s.base!.join('\n')}' : 'Unresolved conflict',
                style: monoStyle(size: 12, color: AppColors.textMuted),
              ),
            ),
        ],
      ),
    );
  }
}
