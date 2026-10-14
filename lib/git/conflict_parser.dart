/// Pieces of a file containing git conflict markers.
sealed class MergeSegment {}

class TextSegment extends MergeSegment {
  TextSegment(this.lines);
  final List<String> lines;
}

enum ConflictChoice { unresolved, ours, theirs, oursThenTheirs, theirsThenOurs, base, custom }

class ConflictSegment extends MergeSegment {
  ConflictSegment(this.ours, this.base, this.theirs);

  final List<String> ours;
  final List<String>? base;
  final List<String> theirs;

  ConflictChoice choice = ConflictChoice.unresolved;
  List<String> custom = const [];

  bool get resolved => choice != ConflictChoice.unresolved;

  List<String> get result => switch (choice) {
        ConflictChoice.unresolved => const [],
        ConflictChoice.ours => ours,
        ConflictChoice.theirs => theirs,
        ConflictChoice.oursThenTheirs => [...ours, ...theirs],
        ConflictChoice.theirsThenOurs => [...theirs, ...ours],
        ConflictChoice.base => base ?? const [],
        ConflictChoice.custom => custom,
      };
}

final _start = RegExp(r'^<{7}( |$)');
final _base = RegExp(r'^\|{7}( |$)');
final _mid = RegExp(r'^={7}$');
final _end = RegExp(r'^>{7}( |$)');

bool hasConflictMarkers(String text) =>
    text.split('\n').any((l) => _start.hasMatch(l.trimRight()));

/// Parses [text] into plain and conflicting segments. Line endings are
/// normalized to `\n`.
List<MergeSegment> parseConflicts(String text) {
  final lines = text.replaceAll('\r\n', '\n').split('\n');
  final trailingNewline = lines.isNotEmpty && lines.last.isEmpty;
  if (trailingNewline) lines.removeLast();

  final segments = <MergeSegment>[];
  var plain = <String>[];
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    if (!_start.hasMatch(line)) {
      plain.add(line);
      i++;
      continue;
    }
    // Look ahead for a complete conflict block.
    final ours = <String>[];
    List<String>? base;
    final theirs = <String>[];
    var j = i + 1;
    var section = 0; // 0 ours, 1 base, 2 theirs
    var complete = false;
    while (j < lines.length) {
      final l = lines[j];
      if (section == 0 && _base.hasMatch(l)) {
        section = 1;
        base = [];
      } else if (section < 2 && _mid.hasMatch(l)) {
        section = 2;
      } else if (section == 2 && _end.hasMatch(l)) {
        complete = true;
        break;
      } else {
        (section == 0 ? ours : section == 1 ? base! : theirs).add(l);
      }
      j++;
    }
    if (!complete) {
      plain.add(line);
      i++;
      continue;
    }
    if (plain.isNotEmpty) {
      segments.add(TextSegment(plain));
      plain = [];
    }
    segments.add(ConflictSegment(ours, base, theirs));
    i = j + 1;
  }
  if (plain.isNotEmpty) segments.add(TextSegment(plain));
  return segments;
}

String joinSegments(List<MergeSegment> segments, {String eol = '\n'}) {
  final out = <String>[];
  for (final s in segments) {
    switch (s) {
      case TextSegment(:final lines):
        out.addAll(lines);
      case ConflictSegment():
        out.addAll(s.result);
    }
  }
  return out.isEmpty ? '' : '${out.join(eol)}$eol';
}
