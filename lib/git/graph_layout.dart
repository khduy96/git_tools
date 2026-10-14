import 'models.dart';

enum SegmentPart { top, bottom, full }

/// A line drawn in one row of the commit graph. For [SegmentPart.top] it
/// runs from the top of the row at [from] to the node center at [to]; for
/// [SegmentPart.bottom] from the node center at [from] to the bottom at [to];
/// for [SegmentPart.full] straight through lane [from].
class GraphSegment {
  const GraphSegment(this.from, this.to, this.part, this.color);

  final int from;
  final int to;
  final SegmentPart part;
  final int color;
}

class GraphRow {
  const GraphRow(this.lane, this.color, this.segments, this.width);

  final int lane;
  final int color;
  final List<GraphSegment> segments;

  /// Number of lanes used by this row.
  final int width;
}

/// Assigns lanes to commits ordered children-before-parents.
List<GraphRow> layoutGraph(List<Commit> commits) {
  final active = <String?>[];
  final colors = <int>[];
  var nextColor = 0;
  final rows = <GraphRow>[];
  final known = {for (final c in commits) c.hash};

  int freeLane() {
    final i = active.indexOf(null);
    if (i >= 0) return i;
    active.add(null);
    colors.add(0);
    return active.length - 1;
  }

  for (final c in commits) {
    final segments = <GraphSegment>[];
    var idx = active.indexOf(c.hash);
    final int color;
    if (idx < 0) {
      idx = freeLane();
      color = nextColor++;
      colors[idx] = color;
    } else {
      color = colors[idx];
    }

    for (var j = 0; j < active.length; j++) {
      final h = active[j];
      if (h == null) continue;
      if (h == c.hash) {
        segments.add(GraphSegment(j, idx, SegmentPart.top, colors[j]));
      } else {
        segments.add(GraphSegment(j, j, SegmentPart.full, colors[j]));
      }
    }
    final widthBefore = active.length;

    for (var j = 0; j < active.length; j++) {
      if (j != idx && active[j] == c.hash) active[j] = null;
    }

    // Parents outside the loaded range are not drawn.
    final parents = c.parents.where(known.contains).toList();
    if (parents.isEmpty) {
      active[idx] = null;
    } else {
      active[idx] = parents.first;
      segments.add(GraphSegment(idx, idx, SegmentPart.bottom, colors[idx]));
      for (final p in parents.skip(1)) {
        var k = active.indexOf(p);
        if (k < 0) {
          k = freeLane();
          active[k] = p;
          colors[k] = nextColor++;
        }
        segments.add(GraphSegment(idx, k, SegmentPart.bottom, colors[k]));
      }
    }

    final width = [widthBefore, active.length, idx + 1]
        .reduce((a, b) => a > b ? a : b);
    while (active.isNotEmpty && active.last == null) {
      active.removeLast();
      colors.removeLast();
    }
    rows.add(GraphRow(idx, color, segments, width));
  }
  return rows;
}
