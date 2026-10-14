import 'package:flutter/material.dart';

import '../common.dart';

/// Two panes separated by a draggable divider. The size of the first pane
/// (or the second when [sizeSecond] is set) is kept in pixels.
class SplitView extends StatefulWidget {
  const SplitView({
    super.key,
    required this.axis,
    required this.first,
    required this.second,
    this.initialSize = 300,
    this.minSize = 80,
    this.sizeSecond = false,
    this.showFirst = true,
    this.showSecond = true,
  });

  final Axis axis;
  final Widget first;
  final Widget second;
  final double initialSize;
  final double minSize;
  final bool sizeSecond;
  final bool showFirst;
  final bool showSecond;

  @override
  State<SplitView> createState() => _SplitViewState();
}

class _SplitViewState extends State<SplitView> {
  late double _size = widget.initialSize;
  bool _hover = false;
  bool _drag = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.showFirst) return widget.second;
    if (!widget.showSecond) return widget.first;
    final horizontal = widget.axis == Axis.horizontal;
    return LayoutBuilder(builder: (context, c) {
      final total = horizontal ? c.maxWidth : c.maxHeight;
      final maxSize = (total - widget.minSize - 4).clamp(widget.minSize, double.infinity);
      final size = _size.clamp(widget.minSize, maxSize);
      final fixed = SizedBox(
        width: horizontal ? size : null,
        height: horizontal ? null : size,
        child: widget.sizeSecond ? widget.second : widget.first,
      );
      final flexible = Expanded(
          child: widget.sizeSecond ? widget.first : widget.second);
      final divider = MouseRegion(
        cursor: horizontal
            ? SystemMouseCursors.resizeColumn
            : SystemMouseCursors.resizeRow,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => setState(() => _drag = true),
          onPanEnd: (_) => setState(() => _drag = false),
          onPanUpdate: (d) {
            final delta = horizontal ? d.delta.dx : d.delta.dy;
            setState(() {
              _size = (size + (widget.sizeSecond ? -delta : delta))
                  .clamp(widget.minSize, maxSize);
            });
          },
          child: Container(
            width: horizontal ? 4 : null,
            height: horizontal ? null : 4,
            color: AppColors.divider,
            alignment: Alignment.center,
            child: Container(
              width: horizontal ? 1 : null,
              height: horizontal ? null : 1,
              color: _hover || _drag ? AppColors.accent : AppColors.border,
            ),
          ),
        ),
      );
      final children = widget.sizeSecond
          ? [flexible, divider, fixed]
          : [fixed, divider, flexible];
      return horizontal
          ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: children)
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
    });
  }
}
