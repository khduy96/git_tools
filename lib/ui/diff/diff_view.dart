import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../git/models.dart';
import '../../git/text_diff.dart';
import '../../state/app_settings.dart';
import '../../state/repo_controller.dart';
import '../common.dart';

const _rowHeight = 19.0;
const _middleWidth = 30.0;
const _imageExts = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'ico'};

class _Side {
  _Side(this.bytes);

  final Uint8List? bytes;

  bool get exists => bytes != null;

  bool get binary {
    final b = bytes;
    if (b == null) return false;
    final n = math.min(b.length, 8000);
    for (var i = 0; i < n; i++) {
      if (b[i] == 0) return true;
    }
    return false;
  }

  String get text => bytes == null ? '' : utf8.decode(bytes!, allowMalformed: true);
}

class _Loaded {
  _Loaded(this.left, this.right, this.diff, this.leftOrig, this.rightOrig);

  final _Side left;
  final _Side right;
  final TextDiff? diff;
  final String leftOrig;
  final String rightOrig;
}

TextDiff _computeDiff((String, String, bool) args) =>
    TextDiff.compute(args.$1, args.$2, ignoreWhitespace: args.$3);

class DiffView extends StatefulWidget {
  const DiffView({
    super.key,
    required this.controller,
    required this.request,
    required this.settings,
  });

  final RepoController controller;
  final DiffRequest request;
  final AppSettings settings;

  @override
  State<DiffView> createState() => _DiffViewState();
}

class _DiffViewState extends State<DiffView> {
  _Loaded? _data;
  Object? _error;
  bool _loading = true;
  Set<int> _expanded = {};
  List<SideRow>? _sideRows;
  List<UnifiedRow>? _unifiedRows;
  int _currentBlock = -1;
  int _loadGen = 0;

  final _v = ScrollController();
  final _h = ScrollController();
  final _hOffset = ValueNotifier<double>(0);
  final _focus = FocusNode();
  late double _charWidth;

  DiffRequest get req => widget.request;
  AppSettings get settings => widget.settings;
  bool get _rightIsWorkingTree => req.right is WorkingTreeRev;

  @override
  void initState() {
    super.initState();
    final tp = TextPainter(
      text: TextSpan(text: 'MMMMMMMMMM', style: monoStyle()),
      textDirection: TextDirection.ltr,
    )..layout();
    _charWidth = tp.width / 10;
    _h.addListener(() => _hOffset.value = _h.offset);
    settings.addListener(_onSettings);
    widget.controller.status.addListener(_onStatus);
    _load();
  }

  @override
  void didUpdateWidget(DiffView old) {
    super.didUpdateWidget(old);
    if (old.request.key != req.key) {
      _expanded = {};
      _currentBlock = -1;
      _load();
    }
  }

  @override
  void dispose() {
    settings.removeListener(_onSettings);
    widget.controller.status.removeListener(_onStatus);
    _v.dispose();
    _h.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool _lastIgnoreWs = false;

  void _onSettings() {
    if (_lastIgnoreWs != settings.ignoreWhitespace) {
      _load();
    } else {
      setState(_buildRows);
    }
  }

  void _onStatus() {
    if (_rightIsWorkingTree) _load(quiet: true);
  }

  Future<void> _load({bool quiet = false}) async {
    final gen = ++_loadGen;
    if (!quiet) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final repo = widget.controller.repo;
      final results = await Future.wait([
        repo.fileBytes(req.left, req.leftPath),
        repo.fileBytes(req.right, req.rightPath),
      ]);
      final left = _Side(results[0] == null ? null : Uint8List.fromList(results[0]!));
      final right = _Side(results[1] == null ? null : Uint8List.fromList(results[1]!));
      TextDiff? diff;
      String lo = '', ro = '';
      if (!left.binary && !right.binary) {
        lo = left.text;
        ro = right.text;
        final lt = lo.replaceAll('\t', '    ');
        final rt = ro.replaceAll('\t', '    ');
        _lastIgnoreWs = settings.ignoreWhitespace;
        final args = (lt, rt, settings.ignoreWhitespace);
        diff = lt.length + rt.length > 200000
            ? await Isolate.run(() => _computeDiff(args))
            : _computeDiff(args);
      }
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _data = _Loaded(left, right, diff, lo, ro);
        _loading = false;
        _buildRows();
      });
    } catch (e) {
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  void _buildRows() {
    final d = _data?.diff;
    if (d == null) {
      _sideRows = null;
      _unifiedRows = null;
      return;
    }
    if (settings.sideBySide) {
      _sideRows = buildSideRows(d,
          collapse: settings.collapseUnchanged, expanded: _expanded);
      _unifiedRows = null;
    } else {
      _unifiedRows = buildUnifiedRows(d,
          collapse: settings.collapseUnchanged, expanded: _expanded);
      _sideRows = null;
    }
  }

  int get _rowCount => _sideRows?.length ?? _unifiedRows?.length ?? 0;

  int _rowBlock(int i) =>
      _sideRows != null ? _sideRows![i].block : _unifiedRows![i].block;

  List<int> get _blockStarts {
    final starts = <int>[];
    var last = -1;
    for (var i = 0; i < _rowCount; i++) {
      final b = _rowBlock(i);
      if (b >= 0 && b != last) starts.add(i);
      if (b >= 0) last = b;
    }
    return starts;
  }

  void _gotoBlock(int delta) {
    final starts = _blockStarts;
    if (starts.isEmpty) return;
    final viewTop = _v.hasClients ? _v.offset / _rowHeight : 0;
    int target;
    if (delta > 0) {
      target = starts.firstWhere((s) => s > viewTop + 3, orElse: () => starts.first);
    } else {
      target = starts.lastWhere((s) => s < viewTop + 2, orElse: () => starts.last);
    }
    _scrollToRow(target);
    setState(() => _currentBlock = _rowBlock(target));
  }

  void _scrollToRow(int row) {
    if (!_v.hasClients) return;
    final pos = _v.position;
    final y = (row * _rowHeight - pos.viewportDimension / 3)
        .clamp(0.0, pos.maxScrollExtent);
    _v.animateTo(y, duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
  }

  void _expandFold(int foldId) {
    setState(() {
      _expanded = {..._expanded, foldId};
      _buildRows();
    });
  }

  Future<void> _revertBlock(int blockIndex) async {
    final data = _data!;
    final d = data.diff!;
    final blk = d.blocks[blockIndex];
    final leftLines = splitLines(data.leftOrig);
    final rightLines = splitLines(data.rightOrig);
    final eol = data.rightOrig.contains('\r\n') ? '\r\n' : '\n';
    final trailing = data.rightOrig.isEmpty ||
        data.rightOrig.endsWith('\n') ||
        rightLines.isEmpty;
    final result = [
      ...rightLines.sublist(0, blk.bStart),
      ...leftLines.sublist(blk.aStart, blk.aEnd),
      ...rightLines.sublist(blk.bEnd),
    ];
    final text = result.join(eol) + (trailing && result.isNotEmpty ? eol : '');
    final file = File(p.join(widget.controller.root, req.rightPath));
    await file.writeAsString(text);
    await _load(quiet: true);
    await widget.controller.refreshStatus();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f7): () => _gotoBlock(1),
        const SingleActivator(LogicalKeyboardKey.f7, shift: true): () => _gotoBlock(-1),
        const SingleActivator(LogicalKeyboardKey.arrowDown, control: true, alt: true): () => _gotoBlock(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp, control: true, alt: true): () => _gotoBlock(-1),
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: Container(
          color: AppColors.background,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _toolbar(),
              const Divider(),
              Expanded(child: _body()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolbar() {
    final d = _data?.diff;
    final count = d?.blocks.length ?? 0;
    return Container(
      height: 34,
      color: AppColors.panel,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          ToolButton(
            icon: Icons.arrow_upward,
            tooltip: 'Previous Difference (Shift+F7)',
            onPressed: count > 0 ? () => _gotoBlock(-1) : null,
          ),
          ToolButton(
            icon: Icons.arrow_downward,
            tooltip: 'Next Difference (F7)',
            onPressed: count > 0 ? () => _gotoBlock(1) : null,
          ),
          const _ToolbarSep(),
          _ModeButton(
            label: settings.sideBySide ? 'Side-by-side viewer' : 'Unified viewer',
            onChanged: (sbs) {
              settings.sideBySide = sbs;
              settings.save();
            },
            value: settings.sideBySide,
          ),
          const _ToolbarSep(),
          ToolButton(
            icon: Icons.unfold_less,
            tooltip: 'Collapse Unchanged Fragments',
            selected: settings.collapseUnchanged,
            onPressed: () {
              settings.collapseUnchanged = !settings.collapseUnchanged;
              _expanded = {};
              settings.save();
            },
          ),
          ToolButton(
            icon: Icons.space_bar,
            tooltip: 'Ignore Whitespaces',
            selected: settings.ignoreWhitespace,
            onPressed: () {
              settings.ignoreWhitespace = !settings.ignoreWhitespace;
              settings.save();
            },
          ),
          ToolButton(
            icon: Icons.refresh,
            tooltip: 'Reload',
            onPressed: () => _load(),
          ),
          const SizedBox(width: 12),
          if (d != null)
            Text(
              d.identical
                  ? 'Contents are identical'
                  : '$count difference${count == 1 ? '' : 's'}'
                      '${_currentBlock >= 0 ? ' · ${_currentBlock + 1}/$count' : ''}',
              style: const TextStyle(fontSize: 12, color: AppColors.textDim),
            ),
          const Spacer(),
          if (d != null && !d.identical) ...[
            Text('+${d.insertedLines}',
                style: const TextStyle(fontSize: 12, color: AppColors.added)),
            const SizedBox(width: 6),
            Text('-${d.deletedLines}',
                style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
            const SizedBox(width: 8),
          ],
          ToolButton(
            icon: Icons.copy_outlined,
            tooltip: 'Copy Path',
            onPressed: () => copyToClipboard(context, req.rightPath),
          ),
        ],
      ),
    );
  }

  Widget _titles() {
    Widget title(String t, String path) => Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: t, style: const TextStyle(color: AppColors.text)),
                TextSpan(
                    text: '   $path',
                    style: const TextStyle(color: AppColors.textMuted)),
              ]),
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        );
    return Container(
      height: 26,
      color: AppColors.panelAlt,
      child: settings.sideBySide
          ? Row(children: [
              title(req.leftTitle, req.leftPath),
              const SizedBox(width: _middleWidth),
              title(req.rightTitle, req.rightPath),
            ])
          : Row(children: [
              title('${req.leftTitle} → ${req.rightTitle}', req.rightPath),
            ]),
    );
  }

  Widget _body() {
    if (_loading && _data == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_error != null) {
      return EmptyHint('Cannot load diff:\n$_error', icon: Icons.error_outline);
    }
    final data = _data!;
    if (data.diff == null) return _binaryView(data);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _titles(),
        const Divider(),
        Expanded(
          child: LayoutBuilder(builder: (context, c) {
            return Row(
              children: [
                Expanded(child: _textArea(c.maxWidth - 14)),
                _OverviewRuler(
                  rows: _rowCount,
                  kindAt: (i) => _sideRows != null
                      ? _sideRows![i].kind
                      : _unifiedRows![i].kind,
                  onJump: _scrollToRow,
                ),
              ],
            );
          }),
        ),
      ],
    );
  }

  Widget _binaryView(_Loaded data) {
    final ext = p.extension(req.rightPath).replaceFirst('.', '').toLowerCase();
    String size(_Side s) => s.exists ? '${s.bytes!.length} bytes' : 'does not exist';
    if (_imageExts.contains(ext)) {
      Widget img(_Side s, String title) => Expanded(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text('$title · ${size(s)}',
                      style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
                ),
                Expanded(
                  child: s.exists
                      ? InteractiveViewer(
                          child: Center(child: Image.memory(s.bytes!, errorBuilder: (_, _, _) => const Text('Cannot decode image'))),
                        )
                      : const EmptyHint('(none)'),
                ),
              ],
            ),
          );
      return Row(children: [
        img(data.left, req.leftTitle),
        const VerticalDivider(width: 1),
        img(data.right, req.rightTitle),
      ]);
    }
    return EmptyHint(
      'Binary files differ\n\n${req.leftTitle}: ${size(data.left)}\n${req.rightTitle}: ${size(data.right)}',
      icon: Icons.memory,
    );
  }

  int get _maxLineLength {
    final d = _data!.diff!;
    var m = 0;
    for (final l in d.left) {
      if (l.length > m) m = l.length;
    }
    for (final l in d.right) {
      if (l.length > m) m = l.length;
    }
    return math.min(m, 2000);
  }

  double _gutterWidth() {
    final d = _data!.diff!;
    final digits = math.max(d.left.length, d.right.length).toString().length;
    return math.max(3, digits) * _charWidth * 0.92 + 16;
  }

  Widget _textArea(double width) {
    final gutter = _gutterWidth();
    final sbs = settings.sideBySide;
    final textViewport = sbs
        ? (width - _middleWidth) / 2 - gutter
        : width - gutter * 2 - 20;
    final contentWidth = _maxLineLength * _charWidth + 40;
    final extra = math.max(0.0, contentWidth - textViewport);

    final list = Listener(
      onPointerSignal: (e) {
        if (e is PointerScrollEvent && _h.hasClients) {
          final shift = HardwareKeyboard.instance.isShiftPressed;
          final dx = e.scrollDelta.dx != 0 ? e.scrollDelta.dx : (shift ? e.scrollDelta.dy : 0.0);
          if (dx != 0) {
            _h.jumpTo((_h.offset + dx).clamp(0.0, _h.position.maxScrollExtent));
          }
        }
      },
      child: Scrollbar(
        controller: _v,
        child: ListView.builder(
          controller: _v,
          itemExtent: _rowHeight,
          itemCount: _rowCount,
          itemBuilder: (context, i) => sbs
              ? _sideRow(i, gutter)
              : _unifiedRow(i, gutter),
        ),
      ),
    );
    return Column(
      children: [
        Expanded(child: list),
        if (extra > 0)
          SizedBox(
            height: 12,
            child: Scrollbar(
              controller: _h,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _h,
                scrollDirection: Axis.horizontal,
                child: SizedBox(width: width + extra, height: 12),
              ),
            ),
          ),
      ],
    );
  }

  Widget _foldRow(int hidden, int foldId) {
    return InkWell(
      onTap: () => _expandFold(foldId),
      child: Container(
        color: AppColors.panelAlt,
        alignment: Alignment.center,
        child: Text('⋯  $hidden unchanged lines (click to expand)',
            style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
      ),
    );
  }

  Widget _sideRow(int i, double gutter) {
    final r = _sideRows![i];
    if (r.isFold) return _foldRow(r.foldedLines, r.foldId);
    final (lbg, rbg, lhi, rhi) = switch (r.kind) {
      DiffKind.equal => (null, null, null, null),
      DiffKind.modified => (
          AppColors.diffModifiedBg,
          AppColors.diffModifiedBg,
          AppColors.diffModifiedHi,
          AppColors.diffModifiedHi
        ),
      DiffKind.deleted => (AppColors.diffDeletedBg, null, null, null),
      DiffKind.inserted => (null, AppColors.diffInsertedBg, null, null),
    };
    final isBlockStart = r.block >= 0 && (i == 0 || _sideRows![i - 1].block != r.block);
    final canRevert = isBlockStart && _rightIsWorkingTree;
    final markColor = switch (r.kind) {
      DiffKind.modified => AppColors.diffModifiedMark,
      DiffKind.deleted => AppColors.diffDeletedMark,
      DiffKind.inserted => AppColors.diffInsertedMark,
      DiffKind.equal => null,
    };
    return Row(
      children: [
        Expanded(
          child: _lineCell(
            no: r.leftNo,
            text: r.leftText,
            spans: r.leftSpans,
            bg: r.leftText == null && r.kind != DiffKind.equal ? AppColors.diffFiller : lbg,
            hi: lhi,
            gutter: gutter,
          ),
        ),
        Container(
          width: _middleWidth,
          color: markColor?.withValues(alpha: 0.25) ?? AppColors.panelAlt,
          alignment: Alignment.center,
          child: canRevert
              ? Tooltip(
                  message: 'Revert this change',
                  child: InkWell(
                    onTap: () => _revertBlock(r.block),
                    child: const Icon(Icons.keyboard_double_arrow_right,
                        size: 14, color: AppColors.textDim),
                  ),
                )
              : null,
        ),
        Expanded(
          child: _lineCell(
            no: r.rightNo,
            text: r.rightText,
            spans: r.rightSpans,
            bg: r.rightText == null && r.kind != DiffKind.equal ? AppColors.diffFiller : rbg,
            hi: rhi ?? (r.kind == DiffKind.inserted ? AppColors.diffInsertedHi : null),
            gutter: gutter,
          ),
        ),
      ],
    );
  }

  Widget _unifiedRow(int i, double gutter) {
    final r = _unifiedRows![i];
    if (r.isFold) return _foldRow(r.foldedLines, r.foldId);
    final (bg, hi, marker) = switch (r.kind) {
      DiffKind.deleted => (AppColors.diffDeletedBg, AppColors.diffDeletedHi, '-'),
      DiffKind.inserted => (AppColors.diffInsertedBg, AppColors.diffInsertedHi, '+'),
      _ => (null, null, ' '),
    };
    final numStyle = monoStyle(size: 12, color: AppColors.textMuted);
    return Container(
      color: bg,
      child: Row(
        children: [
          SizedBox(
            width: gutter,
            child: Text(r.leftNo?.toString() ?? '',
                textAlign: TextAlign.right, style: numStyle),
          ),
          SizedBox(
            width: gutter,
            child: Text(r.rightNo?.toString() ?? '',
                textAlign: TextAlign.right, style: numStyle),
          ),
          SizedBox(
            width: 20,
            child: Text(marker, textAlign: TextAlign.center, style: numStyle),
          ),
          Expanded(child: _scrolledText(r.text, r.spans, hi)),
        ],
      ),
    );
  }

  Widget _lineCell({
    required int? no,
    required String? text,
    required List<Span> spans,
    required Color? bg,
    required Color? hi,
    required double gutter,
  }) {
    return Container(
      color: bg,
      child: Row(
        children: [
          SizedBox(
            width: gutter,
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(no?.toString() ?? '',
                  textAlign: TextAlign.right,
                  style: monoStyle(size: 12, color: AppColors.textMuted)),
            ),
          ),
          Expanded(
            child: text == null
                ? const SizedBox.shrink()
                : _scrolledText(text, spans, hi),
          ),
        ],
      ),
    );
  }

  Widget _scrolledText(String text, List<Span> spans, Color? hi) {
    final shown = text.length > 2000 ? text.substring(0, 2000) : text;
    final style = monoStyle();
    InlineSpan content;
    if (spans.isEmpty || hi == null) {
      content = TextSpan(text: shown, style: style);
    } else {
      final children = <TextSpan>[];
      var pos = 0;
      for (final s in spans) {
        final st = math.min(s.start, shown.length), en = math.min(s.end, shown.length);
        if (st > pos) children.add(TextSpan(text: shown.substring(pos, st)));
        if (en > st) {
          children.add(TextSpan(
              text: shown.substring(st, en),
              style: TextStyle(backgroundColor: hi)));
        }
        pos = math.max(pos, en);
      }
      if (pos < shown.length) children.add(TextSpan(text: shown.substring(pos)));
      content = TextSpan(style: style, children: children);
    }
    return ClipRect(
      child: ValueListenableBuilder<double>(
        valueListenable: _hOffset,
        builder: (context, h, child) => Transform.translate(
          offset: Offset(-h, 0),
          child: child,
        ),
        child: OverflowBox(
          alignment: Alignment.centerLeft,
          minWidth: 0,
          maxWidth: double.infinity,
          child: Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text.rich(content, softWrap: false, maxLines: 1),
          ),
        ),
      ),
    );
  }
}

class _ToolbarSep extends StatelessWidget {
  const _ToolbarSep();

  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 18,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        color: AppColors.border,
      );
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<bool>(
      tooltip: 'Viewer mode',
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (_) => [
        menuItem(true, 'Side-by-side viewer', icon: Icons.vertical_split_outlined),
        menuItem(false, 'Unified viewer', icon: Icons.view_agenda_outlined),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: const TextStyle(fontSize: 12.5, color: AppColors.text)),
            const Icon(Icons.arrow_drop_down, size: 18, color: AppColors.textDim),
          ],
        ),
      ),
    );
  }
}

/// Thin strip showing where changes are, like the editor error stripe.
class _OverviewRuler extends StatelessWidget {
  const _OverviewRuler({
    required this.rows,
    required this.kindAt,
    required this.onJump,
  });

  final int rows;
  final DiffKind Function(int) kindAt;
  final void Function(int row) onJump;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      return GestureDetector(
        onTapDown: (d) {
          if (rows == 0) return;
          onJump((d.localPosition.dy / c.maxHeight * rows).floor().clamp(0, rows - 1));
        },
        child: CustomPaint(
          size: Size(14, c.maxHeight),
          painter: _RulerPainter(rows, kindAt),
        ),
      );
    });
  }
}

class _RulerPainter extends CustomPainter {
  _RulerPainter(this.rows, this.kindAt);

  final int rows;
  final DiffKind Function(int) kindAt;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = AppColors.panelAlt);
    if (rows == 0) return;
    final scale = size.height / rows;
    final paint = Paint();
    for (var i = 0; i < rows; i++) {
      final k = kindAt(i);
      if (k == DiffKind.equal) continue;
      paint.color = switch (k) {
        DiffKind.modified => AppColors.diffModifiedMark,
        DiffKind.deleted => AppColors.diffDeletedMark,
        _ => AppColors.diffInsertedMark,
      };
      canvas.drawRect(
          Rect.fromLTWH(3, i * scale, size.width - 6, math.max(2, scale)), paint);
    }
  }

  @override
  bool shouldRepaint(_RulerPainter old) => true;
}
