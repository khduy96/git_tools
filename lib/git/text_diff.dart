import 'dart:math' as math;
import 'dart:typed_data';

/// A changed region: lines [aStart, aEnd) on the left were replaced by
/// lines [bStart, bEnd) on the right.
class DiffBlock {
  const DiffBlock(this.aStart, this.aEnd, this.bStart, this.bEnd);

  final int aStart, aEnd, bStart, bEnd;

  int get aLen => aEnd - aStart;
  int get bLen => bEnd - bStart;

  DiffKind get kind => aLen == 0
      ? DiffKind.inserted
      : bLen == 0
          ? DiffKind.deleted
          : DiffKind.modified;
}

enum DiffKind { equal, modified, inserted, deleted }

/// Myers O(ND) diff over integer sequences. Falls back to a single
/// replacement block when the edit distance exceeds [maxD].
List<DiffBlock> diffSequences(List<int> a, List<int> b, {int maxD = 4000}) {
  var start = 0;
  var endA = a.length, endB = b.length;
  while (start < endA && start < endB && a[start] == b[start]) {
    start++;
  }
  while (endA > start && endB > start && a[endA - 1] == b[endB - 1]) {
    endA--;
    endB--;
  }
  final n = endA - start, m = endB - start;
  if (n == 0 && m == 0) return const [];
  if (n == 0 || m == 0) {
    return [DiffBlock(start, endA, start, endB)];
  }

  final max = n + m;
  final off = max + 1;
  final v = Int32List(2 * max + 3);
  final trace = <Int32List>[];
  var found = false;
  var dFinal = 0;

  for (var d = 0; d <= max; d++) {
    if (d > maxD) break;
    for (var k = -d; k <= d; k += 2) {
      int x;
      if (k == -d || (k != d && v[off + k - 1] < v[off + k + 1])) {
        x = v[off + k + 1];
      } else {
        x = v[off + k - 1] + 1;
      }
      var y = x - k;
      while (x < n && y < m && a[start + x] == b[start + y]) {
        x++;
        y++;
      }
      v[off + k] = x;
      if (x >= n && y >= m) {
        found = true;
      }
    }
    final snap = Int32List(2 * d + 1);
    for (var k = -d; k <= d; k++) {
      snap[k + d] = v[off + k];
    }
    trace.add(snap);
    if (found) {
      dFinal = d;
      break;
    }
  }
  if (!found) return [DiffBlock(start, endA, start, endB)];

  // Backtrack, collecting edits as (x, y, isInsert) in reverse.
  final edits = <(int, int, bool)>[];
  var x = n, y = m;
  for (var d = dFinal; d > 0; d--) {
    final prev = trace[d - 1];
    final k = x - y;
    int prevVal(int kk) => prev[kk + d - 1];
    final int prevK;
    if (k == -d || (k != d && prevVal(k - 1) < prevVal(k + 1))) {
      prevK = k + 1;
    } else {
      prevK = k - 1;
    }
    final prevX = prevVal(prevK);
    final prevY = prevX - prevK;
    while (x > prevX && y > prevY) {
      x--;
      y--;
    }
    if (x == prevX) {
      edits.add((prevX, prevY, true)); // insert b[prevY]
    } else {
      edits.add((prevX, prevY, false)); // delete a[prevX]
    }
    x = prevX;
    y = prevY;
  }

  // Group consecutive edits into blocks.
  final blocks = <DiffBlock>[];
  int? bas, bae, bbs, bbe;
  for (final (ax, ay, ins) in edits.reversed) {
    final aEndHere = ins ? ax : ax + 1;
    final bEndHere = ins ? ay + 1 : ay;
    if (bas != null && ax <= bae! && ay <= bbe!) {
      bae = math.max(bae, aEndHere);
      bbe = math.max(bbe, bEndHere);
    } else {
      if (bas != null) {
        blocks.add(DiffBlock(start + bas, start + bae!, start + bbs!, start + bbe!));
      }
      bas = ax;
      bae = aEndHere;
      bbs = ay;
      bbe = bEndHere;
    }
  }
  if (bas != null) {
    blocks.add(DiffBlock(start + bas, start + bae!, start + bbs!, start + bbe!));
  }
  return blocks;
}

List<String> splitLines(String text) {
  if (text.isEmpty) return const [];
  final lines = text.split('\n');
  if (lines.last.isEmpty) lines.removeLast();
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    if (l.endsWith('\r')) lines[i] = l.substring(0, l.length - 1);
  }
  return lines;
}

class TextDiff {
  TextDiff._(this.left, this.right, this.blocks);

  final List<String> left;
  final List<String> right;
  final List<DiffBlock> blocks;

  bool get identical => blocks.isEmpty;

  int get insertedLines => blocks.fold(0, (s, b) => s + b.bLen);
  int get deletedLines => blocks.fold(0, (s, b) => s + b.aLen);

  factory TextDiff.compute(String leftText, String rightText,
      {bool ignoreWhitespace = false}) {
    final left = splitLines(leftText);
    final right = splitLines(rightText);
    final ids = <String, int>{};
    int id(String line) {
      final key =
          ignoreWhitespace ? line.replaceAll(RegExp(r'\s+'), '') : line;
      return ids.putIfAbsent(key, () => ids.length);
    }

    final a = left.map(id).toList();
    final b = right.map(id).toList();
    return TextDiff._(left, right, diffSequences(a, b));
  }
}

/// A character range within a line to highlight.
class Span {
  const Span(this.start, this.end);
  final int start, end;
}

final _token = RegExp(r'\w+|\s+|.', unicode: true);

/// Word-level differences between two lines. Returns highlighted ranges
/// for the left and right line.
(List<Span>, List<Span>) intraline(String a, String b) {
  if (a.length > 1000 || b.length > 1000) return (const [], const []);
  final ta = _token.allMatches(a).toList();
  final tb = _token.allMatches(b).toList();
  final ids = <String, int>{};
  int id(Match m) => ids.putIfAbsent(m.group(0)!, () => ids.length);
  final blocks =
      diffSequences(ta.map(id).toList(), tb.map(id).toList(), maxD: 300);
  final sa = <Span>[], sb = <Span>[];
  for (final blk in blocks) {
    if (blk.aLen > 0) {
      sa.add(Span(ta[blk.aStart].start, ta[blk.aEnd - 1].end));
    }
    if (blk.bLen > 0) {
      sb.add(Span(tb[blk.bStart].start, tb[blk.bEnd - 1].end));
    }
  }
  return (sa, sb);
}

/// One row of the side-by-side viewer.
class SideRow {
  const SideRow({
    this.leftNo,
    this.rightNo,
    this.leftText,
    this.rightText,
    this.kind = DiffKind.equal,
    this.block = -1,
    this.leftSpans = const [],
    this.rightSpans = const [],
    this.foldedLines = 0,
    this.foldId = -1,
  });

  /// 1-based line numbers; null for filler rows.
  final int? leftNo, rightNo;
  final String? leftText, rightText;
  final DiffKind kind;
  final int block;
  final List<Span> leftSpans, rightSpans;

  /// When > 0 this row is a collapsed region placeholder.
  final int foldedLines;
  final int foldId;

  bool get isFold => foldedLines > 0;
}

/// One row of the unified viewer.
class UnifiedRow {
  const UnifiedRow({
    this.leftNo,
    this.rightNo,
    this.text = '',
    this.kind = DiffKind.equal,
    this.block = -1,
    this.spans = const [],
    this.foldedLines = 0,
    this.foldId = -1,
  });

  final int? leftNo, rightNo;
  final String text;

  /// [DiffKind.deleted] = line from left, [DiffKind.inserted] = from right.
  final DiffKind kind;
  final int block;
  final List<Span> spans;
  final int foldedLines;
  final int foldId;

  bool get isFold => foldedLines > 0;
}

const _context = 4;

/// Builds side-by-side rows. Unchanged runs longer than the context are
/// collapsed unless their fold id is in [expanded] or [collapse] is false.
List<SideRow> buildSideRows(TextDiff d,
    {bool collapse = true, Set<int> expanded = const {}}) {
  final rows = <SideRow>[];
  var ai = 0, bi = 0, fold = 0;

  void equalRun(int aEnd, bool first, bool last) {
    final count = aEnd - ai;
    final keepTop = first ? 0 : _context;
    final keepBottom = last ? 0 : _context;
    final foldId = fold++;
    if (collapse &&
        !expanded.contains(foldId) &&
        count > keepTop + keepBottom + 2) {
      for (var i = 0; i < keepTop; i++) {
        rows.add(SideRow(
            leftNo: ai + 1,
            rightNo: bi + 1,
            leftText: d.left[ai++],
            rightText: d.right[bi++]));
      }
      final hidden = count - keepTop - keepBottom;
      rows.add(SideRow(foldedLines: hidden, foldId: foldId));
      ai += hidden;
      bi += hidden;
      for (var i = 0; i < keepBottom; i++) {
        rows.add(SideRow(
            leftNo: ai + 1,
            rightNo: bi + 1,
            leftText: d.left[ai++],
            rightText: d.right[bi++]));
      }
    } else {
      while (ai < aEnd) {
        rows.add(SideRow(
            leftNo: ai + 1,
            rightNo: bi + 1,
            leftText: d.left[ai++],
            rightText: d.right[bi++]));
      }
    }
  }

  for (var bIdx = 0; bIdx < d.blocks.length; bIdx++) {
    final blk = d.blocks[bIdx];
    equalRun(blk.aStart, bIdx == 0, false);
    final kind = blk.kind;
    final n = math.max(blk.aLen, blk.bLen);
    for (var i = 0; i < n; i++) {
      final hasL = i < blk.aLen, hasR = i < blk.bLen;
      final lt = hasL ? d.left[blk.aStart + i] : null;
      final rt = hasR ? d.right[blk.bStart + i] : null;
      var ls = const <Span>[], rs = const <Span>[];
      if (lt != null && rt != null) {
        (ls, rs) = intraline(lt, rt);
      }
      rows.add(SideRow(
        leftNo: hasL ? blk.aStart + i + 1 : null,
        rightNo: hasR ? blk.bStart + i + 1 : null,
        leftText: lt,
        rightText: rt,
        kind: kind,
        block: bIdx,
        leftSpans: ls,
        rightSpans: rs,
      ));
    }
    ai = blk.aEnd;
    bi = blk.bEnd;
  }
  equalRun(d.left.length, d.blocks.isEmpty, true);
  return rows;
}

List<UnifiedRow> buildUnifiedRows(TextDiff d,
    {bool collapse = true, Set<int> expanded = const {}}) {
  final rows = <UnifiedRow>[];
  var ai = 0, bi = 0, fold = 0;

  void addEqual() {
    rows.add(
        UnifiedRow(leftNo: ai + 1, rightNo: bi + 1, text: d.left[ai]));
    ai++;
    bi++;
  }

  void equalRun(int aEnd, bool first, bool last) {
    final count = aEnd - ai;
    final keepTop = first ? 0 : _context;
    final keepBottom = last ? 0 : _context;
    final foldId = fold++;
    if (collapse &&
        !expanded.contains(foldId) &&
        count > keepTop + keepBottom + 2) {
      for (var i = 0; i < keepTop; i++) {
        addEqual();
      }
      final hidden = count - keepTop - keepBottom;
      rows.add(UnifiedRow(foldedLines: hidden, foldId: foldId));
      ai += hidden;
      bi += hidden;
      for (var i = 0; i < keepBottom; i++) {
        addEqual();
      }
    } else {
      while (ai < aEnd) {
        addEqual();
      }
    }
  }

  for (var bIdx = 0; bIdx < d.blocks.length; bIdx++) {
    final blk = d.blocks[bIdx];
    equalRun(blk.aStart, bIdx == 0, false);
    final pairs = math.min(blk.aLen, blk.bLen);
    final spansL = <int, List<Span>>{}, spansR = <int, List<Span>>{};
    for (var i = 0; i < pairs; i++) {
      final (l, r) =
          intraline(d.left[blk.aStart + i], d.right[blk.bStart + i]);
      spansL[i] = l;
      spansR[i] = r;
    }
    for (var i = 0; i < blk.aLen; i++) {
      rows.add(UnifiedRow(
        leftNo: blk.aStart + i + 1,
        text: d.left[blk.aStart + i],
        kind: DiffKind.deleted,
        block: bIdx,
        spans: spansL[i] ?? const [],
      ));
    }
    for (var i = 0; i < blk.bLen; i++) {
      rows.add(UnifiedRow(
        rightNo: blk.bStart + i + 1,
        text: d.right[blk.bStart + i],
        kind: DiffKind.inserted,
        block: bIdx,
        spans: spansR[i] ?? const [],
      ));
    }
    ai = blk.aEnd;
    bi = blk.bEnd;
  }
  equalRun(d.left.length, d.blocks.isEmpty, true);
  return rows;
}
