import 'package:flutter/material.dart';

import '../../git/graph_layout.dart';
import '../common.dart';

const laneWidth = 14.0;

Color laneColor(int c) => AppColors.graph[c % AppColors.graph.length];

double graphWidth(GraphRow row) => row.width * laneWidth + 6;

class GraphRowPainter extends CustomPainter {
  GraphRowPainter(this.row, {this.isHead = false, this.dimmed = false});

  final GraphRow row;
  final bool isHead;
  final bool dimmed;

  double _x(int lane) => lane * laneWidth + laneWidth / 2 + 2;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    final mid = h / 2;
    final paint = Paint()
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;

    for (final s in row.segments) {
      paint.color = laneColor(s.color).withValues(alpha: dimmed ? 0.35 : 1);
      switch (s.part) {
        case SegmentPart.full:
          canvas.drawLine(Offset(_x(s.from), 0), Offset(_x(s.from), h), paint);
        case SegmentPart.top:
          _curve(canvas, Offset(_x(s.from), 0), Offset(_x(s.to), mid), paint);
        case SegmentPart.bottom:
          _curve(canvas, Offset(_x(s.from), mid), Offset(_x(s.to), h), paint);
      }
    }

    final center = Offset(_x(row.lane), mid);
    final color = laneColor(row.color).withValues(alpha: dimmed ? 0.35 : 1);
    if (isHead) {
      canvas.drawCircle(center, 5, Paint()..color = AppColors.background);
      canvas.drawCircle(
          center,
          4.5,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
    } else {
      canvas.drawCircle(center, 4, Paint()..color = color);
    }
  }

  void _curve(Canvas canvas, Offset a, Offset b, Paint paint) {
    if (a.dx == b.dx) {
      canvas.drawLine(a, b, paint);
      return;
    }
    final path = Path()
      ..moveTo(a.dx, a.dy)
      ..cubicTo(a.dx, (a.dy + b.dy) / 2, b.dx, (a.dy + b.dy) / 2, b.dx, b.dy);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(GraphRowPainter old) =>
      old.row != row || old.isHead != isHead || old.dimmed != dimmed;
}
