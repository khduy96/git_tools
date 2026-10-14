import 'package:flutter/material.dart';

import '../../git/git_process.dart';
import '../../state/repo_controller.dart';
import '../common.dart';

/// The "Console" tab: every git command run by the tool and its output.
class ConsolePanel extends StatefulWidget {
  const ConsolePanel({super.key, required this.controller});

  final RepoController controller;

  @override
  State<ConsolePanel> createState() => _ConsolePanelState();
}

class _ConsolePanelState extends State<ConsolePanel> {
  RepoController get ctrl => widget.controller;
  final _scroll = ScrollController();
  final _input = TextEditingController();
  bool _follow = true;

  @override
  void initState() {
    super.initState();
    ctrl.console.addListener(_onNew);
  }

  @override
  void dispose() {
    ctrl.console.removeListener(_onNew);
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  void _onNew() {
    if (!_follow) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  static List<String> _splitArgs(String s) {
    final args = <String>[];
    final re = RegExp(r'''"([^"]*)"|'([^']*)'|(\S+)''');
    for (final m in re.allMatches(s)) {
      args.add(m.group(1) ?? m.group(2) ?? m.group(3)!);
    }
    return args;
  }

  Future<void> _runCommand() async {
    var text = _input.text.trim();
    if (text.isEmpty) return;
    if (text.startsWith('git ')) text = text.substring(4);
    _input.clear();
    await ctrl.run('git $text', () => ctrl.repo.git.run(_splitArgs(text), log: true));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 32,
                  color: AppColors.panel,
                  child: Column(children: [
                    const SizedBox(height: 4),
                    ToolButton(icon: Icons.delete_sweep_outlined, tooltip: 'Clear All', onPressed: ctrl.clearConsole),
                    ToolButton(
                      icon: Icons.vertical_align_bottom,
                      tooltip: 'Scroll to End',
                      selected: _follow,
                      onPressed: () => setState(() {
                        _follow = !_follow;
                        _onNew();
                      }),
                    ),
                  ]),
                ),
                Expanded(
                  child: ValueListenableBuilder<List<ConsoleEntry>>(
                    valueListenable: ctrl.console,
                    builder: (context, entries, _) => SelectionArea(
                      child: Scrollbar(
                        controller: _scroll,
                        child: ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          itemCount: entries.length,
                          itemBuilder: (context, i) {
                            final e = entries[i];
                            final t = e.time;
                            String two(int v) => v.toString().padLeft(2, '0');
                            final (color, prefix) = switch (e.kind) {
                              ConsoleKind.command => (AppColors.accentHover, ''),
                              ConsoleKind.error => (AppColors.error, ''),
                              ConsoleKind.info => (AppColors.textMuted, ''),
                              ConsoleKind.output => (AppColors.textDim, '    '),
                            };
                            return Text.rich(
                              TextSpan(children: [
                                if (e.kind == ConsoleKind.command || e.kind == ConsoleKind.info)
                                  TextSpan(
                                    text: '${two(t.hour)}:${two(t.minute)}:${two(t.second)}  ',
                                    style: const TextStyle(color: AppColors.textMuted),
                                  ),
                                TextSpan(text: '$prefix${e.text}', style: TextStyle(color: color)),
                              ]),
                              style: monoStyle(size: 12.5),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(),
          SizedBox(
            height: 30,
            child: Row(children: [
              const SizedBox(width: 10),
              Text('git', style: monoStyle(size: 12.5, color: AppColors.accentHover)),
              Expanded(
                child: TextField(
                  controller: _input,
                  style: monoStyle(size: 12.5),
                  decoration: const InputDecoration(
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    hintText: 'Run a git command, e.g. status -sb',
                    contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  ),
                  onSubmitted: (_) => _runCommand(),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}
