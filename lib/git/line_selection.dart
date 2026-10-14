/// Line level selection of changes (Android Studio "partial commit").
///
/// A file diff (HEAD → working tree) is parsed into hunks. Every changed line
/// ('+' or '-') has a stable key `hunk:line` within that diff; the
/// selection is stored as the set of *excluded* keys. From the HEAD content
/// and the selection we build the exact content to commit.
library;

class DiffLineEntry {
  DiffLineEntry(this.kind, this.text);

  /// ' ' context, '+' added, '-' removed.
  final String kind;
  final String text;

  /// The line has no trailing newline ("\ No newline at end of file").
  bool noEol = false;

  bool get isChange => kind != ' ';
}

class DiffHunk {
  DiffHunk(this.oldStart, this.oldLen, this.newStart, this.newLen, this.header);

  final int oldStart, oldLen, newStart, newLen;
  final String header;
  final List<DiffLineEntry> lines = [];
}

class ParsedDiff {
  ParsedDiff(this.hunks, this.binary) : signature = _signature(hunks);

  final List<DiffHunk> hunks;
  final bool binary;

  /// Content hash used to detect that a diff changed since selection.
  final String signature;

  /// All selectable keys.
  List<String> get changeKeys => [
        for (var i = 0; i < hunks.length; i++)
          for (var j = 0; j < hunks[i].lines.length; j++)
            if (hunks[i].lines[j].isChange) lineKey(i, j),
      ];
}

/// Selection of one file: keys of the changes left out of the commit.
class LineSelection {
  LineSelection(this.signature, this.excluded, this.total);

  final String signature;
  final Set<String> excluded;
  final int total;

  int get selected => total - excluded.length;
}

String lineKey(int hunk, int line) => '$hunk:$line';

final _hunkRe = RegExp(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$');

/// Parses the output of `git diff` for a single file.
ParsedDiff parseDiff(String text) {
  final hunks = <DiffHunk>[];
  var binary = false;
  DiffHunk? cur;
  final lines = text.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  for (final line in lines) {
    final m = _hunkRe.firstMatch(line);
    if (m != null) {
      cur = DiffHunk(
        int.parse(m.group(1)!),
        m.group(2) == null ? 1 : int.parse(m.group(2)!),
        int.parse(m.group(3)!),
        m.group(4) == null ? 1 : int.parse(m.group(4)!),
        m.group(5)!.trim(),
      );
      hunks.add(cur);
      continue;
    }
    if (cur == null) {
      if (line.startsWith('Binary files ')) binary = true;
      continue;
    }
    if (line.isEmpty) continue;
    final c = line[0];
    if (c == ' ' || c == '+' || c == '-') {
      cur.lines.add(DiffLineEntry(c, line.substring(1)));
    } else if (c == r'\' && cur.lines.isNotEmpty) {
      cur.lines.last.noEol = true;
    }
  }
  return ParsedDiff(hunks, binary);
}

String _signature(List<DiffHunk> hunks) {
  var h = 0x811c9dc5;
  void mix(String s) {
    for (final u in s.codeUnits) {
      h = ((h ^ u) * 0x01000193) & 0xffffffff;
    }
  }

  for (final hk in hunks) {
    mix('${hk.oldStart},${hk.oldLen},${hk.newStart},${hk.newLen}');
    for (final l in hk.lines) {
      mix('${l.kind}${l.text}${l.noEol ? r'\' : ''}\n');
    }
  }
  return h.toRadixString(16);
}

/// Splits text into lines that keep their terminator.
List<String> splitKeepEol(String text) =>
    RegExp(r'[^\n]*\n|[^\n]+$').allMatches(text).map((m) => m.group(0)!).toList();

/// Content of the file with only the selected changes applied to [oldText].
/// Unselected deletions keep the old line, unselected additions are dropped.
String buildContent(String oldText, ParsedDiff parsed, Set<String> excluded) {
  final old = splitKeepEol(oldText);
  final out = <String>[];
  var oi = 0;
  for (var i = 0; i < parsed.hunks.length; i++) {
    final hk = parsed.hunks[i];
    // A hunk with oldLen 0 inserts after line oldStart.
    final start = hk.oldLen == 0 ? hk.oldStart : hk.oldStart - 1;
    while (oi < start && oi < old.length) {
      out.add(old[oi++]);
    }
    for (var j = 0; j < hk.lines.length; j++) {
      final l = hk.lines[j];
      final selected = !excluded.contains(lineKey(i, j));
      if (l.kind == ' ') {
        if (oi < old.length) out.add(old[oi]);
        oi++;
      } else if (l.kind == '-') {
        if (!selected && oi < old.length) out.add(old[oi]);
        oi++;
      } else if (selected) {
        out.add(l.noEol ? l.text : '${l.text}\n');
      }
    }
  }
  while (oi < old.length) {
    out.add(old[oi++]);
  }
  // Keep lines separated when a kept line lost its terminator.
  for (var k = 0; k < out.length - 1; k++) {
    if (!out[k].endsWith('\n')) out[k] = '${out[k]}\n';
  }
  return out.join();
}

/// Diff text limited to the selected changes (for AI prompts).
String filteredPatch(String path, ParsedDiff parsed, Set<String> excluded) {
  final out = ['diff --git a/$path b/$path', '--- a/$path', '+++ b/$path'];
  var shift = 0;
  for (var i = 0; i < parsed.hunks.length; i++) {
    final hk = parsed.hunks[i];
    final lines = <String>[];
    var oldLen = 0, newLen = 0;
    var changed = false;
    for (var j = 0; j < hk.lines.length; j++) {
      final l = hk.lines[j];
      final selected = !excluded.contains(lineKey(i, j));
      if (l.kind == ' ' || (l.kind == '-' && !selected)) {
        lines.add(' ${l.text}');
        oldLen++;
        newLen++;
      } else if (l.kind == '-') {
        lines.add('-${l.text}');
        oldLen++;
        changed = true;
      } else if (selected) {
        lines.add('+${l.text}');
        newLen++;
        changed = true;
      }
    }
    if (changed) {
      out.add('@@ -${hk.oldStart},$oldLen +${hk.oldStart + shift},$newLen @@'
          '${hk.header.isEmpty ? '' : ' ${hk.header}'}');
      out.addAll(lines);
    }
    shift += newLen - oldLen;
  }
  return '${out.join('\n')}\n';
}

/// Describes excluded lines independently of their position, so a selection
/// survives edits elsewhere in the file: `kind + text + '#' + occurrence`.
Set<String> describeSelection(ParsedDiff parsed, Set<String> excluded) {
  final seen = <String, int>{};
  final out = <String>{};
  for (var i = 0; i < parsed.hunks.length; i++) {
    for (var j = 0; j < parsed.hunks[i].lines.length; j++) {
      final l = parsed.hunks[i].lines[j];
      if (!l.isChange) continue;
      final id = '${l.kind}${l.text}';
      final n = (seen[id] ?? 0) + 1;
      seen[id] = n;
      if (excluded.contains(lineKey(i, j))) out.add('$id#$n');
    }
  }
  return out;
}

/// Maps described exclusions onto the keys of a new diff.
Set<String> remapSelection(ParsedDiff parsed, Set<String> described) {
  final seen = <String, int>{};
  final out = <String>{};
  for (var i = 0; i < parsed.hunks.length; i++) {
    for (var j = 0; j < parsed.hunks[i].lines.length; j++) {
      final l = parsed.hunks[i].lines[j];
      if (!l.isChange) continue;
      final id = '${l.kind}${l.text}';
      final n = (seen[id] ?? 0) + 1;
      seen[id] = n;
      if (described.contains('$id#$n')) out.add(lineKey(i, j));
    }
  }
  return out;
}
