import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../git/line_selection.dart';
import '../../git/models.dart';
import '../../state/repo_controller.dart';
import '../common.dart';

const _rowHeight = 20.0;

/// One rendered row: a hunk header or a diff line.
class _Row {
  _Row.header(this.hunk)
      : line = -1,
        entry = null,
        oldNo = null,
        newNo = null;
  _Row.line(this.hunk, this.line, this.entry, this.oldNo, this.newNo);

  final int hunk;
  final int line;
  final DiffLineEntry? entry;
  final int? oldNo;
  final int? newNo;

  bool get isHeader => line < 0;
}

/// "Commit Lines": tick the changed lines of a file to include in the next
/// commit (Android Studio partial commit).
class LinesView extends StatefulWidget {
  const LinesView({super.key, required this.controller, required this.path});

  final RepoController controller;
  final String path;

  @override
  State<LinesView> createState() => _LinesViewState();
}

class _LinesViewState extends State<LinesView> {
  RepoController get ctrl => widget.controller;

  ParsedDiff? _parsed;
  Set<String> _excluded = {};
  List<_Row> _rows = const [];
  String? _gone;
  bool _loading = true;
  String? _lastKey;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    ctrl.status.addListener(_load);
    ctrl.lineSelections.addListener(_sync);
    ctrl.included.addListener(_sync);
    _load();
  }

  @override
  void dispose() {
    ctrl.status.removeListener(_load);
    ctrl.lineSelections.removeListener(_sync);
    ctrl.included.removeListener(_sync);
    super.dispose();
  }

  /// Selection as stored in the controller for the current diff.
  Set<String> _storedExcluded(ParsedDiff parsed) {
    if (!ctrl.included.value.contains(widget.path)) return parsed.changeKeys.toSet();
    final sel = ctrl.lineSelections.value[widget.path];
    if (sel == null) return {};
    if (sel.signature == parsed.signature) return {...sel.excluded};
    // The file was edited: keep the selection for lines that still exist.
    final prev = _parsed;
    if (prev == null || prev.signature != sel.signature) return {};
    final remapped = remapSelection(parsed, describeSelection(prev, sel.excluded));
    ctrl.setLineSelection(widget.path, parsed.signature, remapped, parsed.changeKeys.length);
    return remapped;
  }

  Future<void> _load() async {
    final gen = ++_gen;
    final change = ctrl.status.value.changes.where((c) => c.path == widget.path).firstOrNull;
    if (!ctrl.canSelectLines(change)) {
      setState(() {
        _loading = false;
        _gone = change == null
            ? 'The file has no changes anymore.'
            : 'Only modified files that exist in HEAD can be committed line by line.';
      });
      return;
    }
    if (ctrl.status.value.state != RepoState.normal) {
      setState(() {
        _loading = false;
        _gone = 'Lines cannot be selected while a merge or rebase is in progress.';
      });
      return;
    }
    final parsed = parseDiff(await ctrl.repo.fileDiff(widget.path));
    if (!mounted || gen != _gen) return;
    if (parsed.binary || parsed.hunks.isEmpty) {
      setState(() {
        _loading = false;
        _gone = parsed.binary ? 'Binary files cannot be committed line by line.' : 'The file has no textual changes.';
      });
      return;
    }
    final excluded = _storedExcluded(parsed);
    setState(() {
      _loading = false;
      _gone = null;
      _parsed = parsed;
      _excluded = excluded;
      _rows = _buildRows(parsed);
    });
  }

  /// Follows changes made from the Commit panel (file checkbox).
  void _sync() {
    final parsed = _parsed;
    if (parsed == null) return;
    final stored = _storedExcluded(parsed);
    if (stored.length != _excluded.length || !stored.containsAll(_excluded)) {
      setState(() => _excluded = stored);
    }
  }

  List<_Row> _buildRows(ParsedDiff parsed) {
    final rows = <_Row>[];
    for (var i = 0; i < parsed.hunks.length; i++) {
      final hk = parsed.hunks[i];
      rows.add(_Row.header(i));
      var oldNo = hk.oldStart - (hk.oldLen == 0 ? 0 : 1);
      var newNo = hk.newStart - (hk.newLen == 0 ? 0 : 1);
      for (var j = 0; j < hk.lines.length; j++) {
        final l = hk.lines[j];
        if (l.kind != '+') oldNo++;
        if (l.kind != '-') newNo++;
        rows.add(_Row.line(i, j, l, l.kind == '+' ? null : oldNo, l.kind == '-' ? null : newNo));
      }
    }
    return rows;
  }

  void _setKeys(Iterable<String> keys, bool include) {
    final parsed = _parsed!;
    final next = {..._excluded};
    for (final k in keys) {
      include ? next.remove(k) : next.add(k);
    }
    setState(() => _excluded = next);
    ctrl.setLineSelection(widget.path, parsed.signature, next, parsed.changeKeys.length);
  }

  /// Click toggles one line; Shift+click applies the same state to a range.
  void _clickLine(String key) {
    final all = _parsed!.changeKeys;
    final last = _lastKey;
    if (HardwareKeyboard.instance.isShiftPressed && last != null) {
      final a = all.indexOf(last), b = all.indexOf(key);
      if (a >= 0 && b >= 0) {
        _setKeys(all.sublist(a < b ? a : b, (a < b ? b : a) + 1), !_excluded.contains(last));
        return;
      }
    }
    _lastKey = key;
    _setKeys([key], _excluded.contains(key));
  }

  List<String> _hunkKeys(int i) => [
        for (var j = 0; j < _parsed!.hunks[i].lines.length; j++)
          if (_parsed!.hunks[i].lines[j].isChange) lineKey(i, j),
      ];

  @override
  Widget build(BuildContext context) {
    final parsed = _parsed;
    final keys = parsed?.changeKeys ?? const <String>[];
    final selected = keys.where((k) => !_excluded.contains(k)).length;
    return Container(
      color: AppColors.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: AppColors.panel,
            padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                Text(widget.path, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                if (_gone == null && parsed != null)
                  Text('$selected of ${keys.length} changed line${keys.length == 1 ? '' : 's'} will be committed',
                      style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
                OutlinedButton(
                  onPressed: parsed == null || _gone != null ? null : () => _setKeys(keys, true),
                  child: const Text('Select All'),
                ),
                OutlinedButton(
                  onPressed: parsed == null || _gone != null ? null : () => _setKeys(keys, false),
                  child: const Text('Select None'),
                ),
                OutlinedButton(
                  onPressed: () {
                    final c = ctrl.status.value.changes.where((x) => x.path == widget.path).firstOrNull;
                    if (c != null) ctrl.showLocalDiff(c);
                  },
                  child: const Text('Open Diff'),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(10, 6, 10, 6),
            child: Text(
              'Tick the changes to include in the next commit. Unticked lines stay in your working copy. '
              'Click a line to toggle it, Shift+click to toggle a range.',
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ),
          const Divider(),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading && _parsed == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_gone != null) return EmptyHint(_gone!, icon: Icons.info_outline);
    return Scrollbar(
      child: ListView.builder(
        itemExtent: _rowHeight + 2,
        itemCount: _rows.length,
        itemBuilder: (context, i) {
          final r = _rows[i];
          return r.isHeader ? _hunkHeader(r.hunk) : _lineRow(r);
        },
      ),
    );
  }

  Widget _hunkHeader(int i) {
    final hk = _parsed!.hunks[i];
    final keys = _hunkKeys(i);
    final n = keys.where((k) => !_excluded.contains(k)).length;
    return Container(
      color: AppColors.panelAlt,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(children: [
        SizedBox(
          width: 26,
          child: Transform.scale(
            scale: 0.8,
            child: Checkbox(
              tristate: true,
              value: n == 0 ? false : n == keys.length ? true : null,
              onChanged: (_) => _setKeys(keys, n != keys.length),
            ),
          ),
        ),
        Text('@@ -${hk.oldStart},${hk.oldLen} +${hk.newStart},${hk.newLen} @@',
            style: monoStyle(size: 12, color: AppColors.textDim)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(hk.header, overflow: TextOverflow.ellipsis, style: monoStyle(size: 12, color: AppColors.textMuted)),
        ),
        Text('$n/${keys.length}', style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
        const SizedBox(width: 8),
      ]),
    );
  }

  Widget _lineRow(_Row r) {
    final l = r.entry!;
    final numStyle = monoStyle(size: 12, color: AppColors.textMuted);
    Widget number(int? n) => SizedBox(
          width: 48,
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(n?.toString() ?? '', textAlign: TextAlign.right, style: numStyle),
          ),
        );
    final text = l.text.replaceAll('\t', '    ') + (l.noEol ? '  ⏎̸' : '');
    if (!l.isChange) {
      return Opacity(
        opacity: 0.75,
        child: Row(children: [
          const SizedBox(width: 30),
          number(r.oldNo),
          number(r.newNo),
          SizedBox(width: 16, child: Text(' ', style: numStyle)),
          Expanded(child: Text(text, softWrap: false, overflow: TextOverflow.clip, style: monoStyle())),
        ]),
      );
    }
    final key = lineKey(r.hunk, r.line);
    final on = !_excluded.contains(key);
    final added = l.kind == '+';
    final bg = added ? AppColors.diffInsertedBg : const Color(0xFF4A2A2E);
    return Tooltip(
      message: on ? 'Included in the commit (click to leave out)' : 'Left out of the commit (click to include)',
      waitDuration: const Duration(milliseconds: 800),
      child: InkWell(
        onTap: () => _clickLine(key),
        child: Container(
          color: on ? bg : null,
          child: Opacity(
            opacity: on ? 1 : 0.5,
            child: Row(children: [
              SizedBox(
                width: 30,
                child: Transform.scale(
                  scale: 0.75,
                  child: Checkbox(value: on, onChanged: (_) => _clickLine(key)),
                ),
              ),
              number(r.oldNo),
              number(r.newNo),
              SizedBox(
                width: 16,
                child: Text(l.kind,
                    textAlign: TextAlign.center,
                    style: monoStyle(color: added ? AppColors.added : AppColors.conflict)),
              ),
              Expanded(
                child: Text(
                  text,
                  softWrap: false,
                  overflow: TextOverflow.clip,
                  style: monoStyle().copyWith(
                    decoration: on ? null : TextDecoration.lineThrough,
                    decorationColor: AppColors.textMuted,
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
