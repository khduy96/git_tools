import 'package:flutter/material.dart';

import '../../git/models.dart';
import '../../state/repo_controller.dart';
import '../common.dart';

/// "Annotate with Git Blame" view.
class BlameView extends StatefulWidget {
  const BlameView({super.key, required this.controller, required this.path});

  final RepoController controller;
  final String path;

  @override
  State<BlameView> createState() => _BlameViewState();
}

class _BlameViewState extends State<BlameView> {
  List<BlameLine>? _lines;
  Object? _error;
  String? _hoverHash;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final lines = await widget.controller.repo.blame(widget.path);
      if (mounted) setState(() => _lines = lines);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _selectCommit(String hash) {
    final ctrl = widget.controller;
    final c = ctrl.commits.value.where((c) => c.hash == hash).firstOrNull;
    if (c != null) {
      ctrl.selectedCommit.value = c;
      ctrl.bottomTab.value = 0;
    } else {
      ctrl.notify(AppNotification('Commit ${hash.substring(0, 8)} is not in the loaded log'));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return EmptyHint('Cannot annotate:\n$_error', icon: Icons.error_outline);
    final lines = _lines;
    if (lines == null) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    if (lines.isEmpty) return const EmptyHint('Empty file');

    // Older commits are drawn with a fainter gutter.
    final times = lines.map((l) => l.time.millisecondsSinceEpoch).toList();
    final minT = times.reduce((a, b) => a < b ? a : b);
    final maxT = times.reduce((a, b) => a > b ? a : b);
    final digits = lines.length.toString().length;

    return Container(
      color: AppColors.background,
      child: Scrollbar(
        controller: _scroll,
        child: ListView.builder(
          controller: _scroll,
          itemExtent: 19,
          itemCount: lines.length,
          itemBuilder: (context, i) {
            final l = lines[i];
            final first = i == 0 || lines[i - 1].hash != l.hash;
            final age = maxT == minT ? 1.0 : (l.time.millisecondsSinceEpoch - minT) / (maxT - minT);
            final uncommitted = l.hash.startsWith('0000000');
            return Row(
              children: [
                MouseRegion(
                  onEnter: (_) => setState(() => _hoverHash = l.hash),
                  onExit: (_) => setState(() => _hoverHash = null),
                  child: GestureDetector(
                    onTap: uncommitted ? null : () => _selectCommit(l.hash),
                    child: Tooltip(
                      message: uncommitted ? 'Not committed yet' : '${l.hash.substring(0, 8)} ${l.author}\n${formatDateFull(l.time)}\n\n${l.summary}',
                      waitDuration: const Duration(milliseconds: 600),
                      child: Container(
                        width: 260,
                        color: _hoverHash == l.hash
                            ? AppColors.selection
                            : Color.lerp(AppColors.panelAlt, const Color(0xFF2F3A4A), age),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: first
                            ? Row(children: [
                                SizedBox(
                                  width: 80,
                                  child: Text(
                                    uncommitted ? '' : formatDate(l.time).replaceFirst(RegExp(r' \d\d:\d\d$'), ''),
                                    style: const TextStyle(fontSize: 11.5, color: AppColors.textDim),
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    uncommitted ? 'Not Committed Yet' : l.author,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11.5, color: AppColors.textDim),
                                  ),
                                ),
                              ])
                            : null,
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: digits * 8.0 + 16,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text('${i + 1}',
                        textAlign: TextAlign.right,
                        style: monoStyle(size: 12, color: AppColors.textMuted)),
                  ),
                ),
                Expanded(
                  child: Text(
                    l.text.replaceAll('\t', '    '),
                    softWrap: false,
                    overflow: TextOverflow.clip,
                    style: monoStyle(),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
