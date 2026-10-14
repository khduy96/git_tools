import 'package:flutter/material.dart';

import '../../git/models.dart';
import '../../state/repo_controller.dart';
import '../common.dart';
import '../dialogs/basic_dialogs.dart';

/// "Compare with current" for a branch: commits on each side and the
/// files that differ.
Future<void> showCompareDialog(
    BuildContext context, RepoController ctrl, String ref) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _CompareDialog(ctrl: ctrl, ref: ref),
  );
}

class _CompareDialog extends StatefulWidget {
  const _CompareDialog({required this.ctrl, required this.ref});

  final RepoController ctrl;
  final String ref;

  @override
  State<_CompareDialog> createState() => _CompareDialogState();
}

class _CompareDialogState extends State<_CompareDialog> {
  RepoController get ctrl => widget.ctrl;
  List<Commit>? _onlyRef;
  List<Commit>? _onlyCurrent;
  List<FileChange>? _files;
  Object? _error;
  int _tab = 0;

  String get _cur => ctrl.status.value.branch ?? 'HEAD';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait([
        ctrl.repo.commitsBetween('HEAD', widget.ref),
        ctrl.repo.commitsBetween(widget.ref, 'HEAD'),
      ]);
      final files = await ctrl.repo.changedFiles('HEAD', widget.ref);
      if (!mounted) return;
      setState(() {
        _onlyRef = r[0];
        _onlyCurrent = r[1];
        _files = files;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppDialog(
      title: 'Compare $_cur with ${widget.ref}',
      width: 820,
      height: 540,
      actions: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
      child: _error != null
          ? EmptyHint('$_error', icon: Icons.error_outline)
          : _files == null
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(children: [
                      _tabBtn(0, 'Log'),
                      _tabBtn(1, 'Files (${_files!.length})'),
                    ]),
                    const SizedBox(height: 6),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: AppColors.border),
                          color: AppColors.background,
                        ),
                        child: _tab == 0 ? _log() : _fileList(),
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _tabBtn(int i, String label) => Padding(
        padding: const EdgeInsets.only(right: 4),
        child: TextButton(
          style: TextButton.styleFrom(
            backgroundColor: _tab == i ? AppColors.hover : null,
            foregroundColor: AppColors.text,
          ),
          onPressed: () => setState(() => _tab = i),
          child: Text(label),
        ),
      );

  Widget _log() {
    Widget section(String title, List<Commit> commits) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              color: AppColors.panelAlt,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              child: Text('$title (${commits.length})',
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
            ),
            if (commits.isEmpty)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text('No commits', style: TextStyle(fontSize: 12.5, color: AppColors.textMuted)),
              ),
            for (final c in commits)
              SizedBox(
                height: 24,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(children: [
                    Text(c.shortHash, style: monoStyle(size: 12, color: AppColors.textMuted)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(c.subject, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                    ),
                    Text(c.authorName, style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
                    const SizedBox(width: 10),
                    Text(formatDate(c.authorTime), style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
                  ]),
                ),
              ),
          ],
        );
    return ListView(
      children: [
        section('Commits in ${widget.ref} that are not in $_cur', _onlyRef!),
        section('Commits in $_cur that are not in ${widget.ref}', _onlyCurrent!),
      ],
    );
  }

  Widget _fileList() {
    final files = _files!;
    if (files.isEmpty) return const EmptyHint('No differences');
    return ListView(
      children: [
        for (final f in files)
          HoverRow(
            onDoubleTap: () {
              Navigator.pop(context);
              ctrl.showCommitDiff(f, widget.ref, 'HEAD', titleSuffix: '(HEAD vs ${widget.ref})');
            },
            child: Row(children: [
              Icon(fileIcon(f.fileName), size: 14, color: changeColor(f.type)),
              const SizedBox(width: 6),
              Text(f.fileName, style: TextStyle(fontSize: 13, color: changeColor(f.type))),
              const SizedBox(width: 8),
              Expanded(
                child: Text(f.directory,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
              ),
              const Text('double-click for diff', style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
            ]),
          ),
      ],
    );
  }
}
