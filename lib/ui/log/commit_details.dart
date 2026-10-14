import 'package:flutter/material.dart';

import '../../git/models.dart';
import '../../state/repo_controller.dart';
import '../common.dart';
import '../widgets/split_view.dart';

/// Right part of the Log tab: changed files and commit message.
class CommitDetailsPanel extends StatefulWidget {
  const CommitDetailsPanel({super.key, required this.controller});

  final RepoController controller;

  @override
  State<CommitDetailsPanel> createState() => _CommitDetailsPanelState();
}

class _CommitDetailsPanelState extends State<CommitDetailsPanel> {
  RepoController get ctrl => widget.controller;
  CommitDetails? _details;
  List<String>? _containedIn;
  Object? _error;
  String? _selectedFile;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    ctrl.selectedCommit.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    ctrl.selectedCommit.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final c = ctrl.selectedCommit.value;
    final gen = ++_gen;
    if (c == null) {
      setState(() {
        _details = null;
        _containedIn = null;
      });
      return;
    }
    if (_details?.commit.hash == c.hash) return;
    setState(() {
      _error = null;
      _containedIn = null;
    });
    try {
      final d = await ctrl.repo.commitDetails(c);
      if (!mounted || gen != _gen) return;
      setState(() => _details = d);
      final branches = await ctrl.repo.branchesContaining(c.hash);
      if (!mounted || gen != _gen) return;
      setState(() => _containedIn = branches);
    } catch (e) {
      if (mounted && gen == _gen) setState(() => _error = e);
    }
  }

  void _openDiff(FileChange f) {
    final c = _details!.commit;
    ctrl.showCommitDiff(f, c.hash, c.parents.isEmpty ? null : c.parents.first);
  }

  Future<void> _fileMenu(Offset pos, FileChange f) async {
    final c = _details!.commit;
    final r = await showContextMenu<String>(context, pos, [
      menuItem('diff', 'Show Diff', icon: Icons.difference_outlined),
      menuItem('local', 'Compare with Local', icon: Icons.compare_arrows, enabled: f.type != ChangeType.deleted),
      menuItem('history', 'Show History for File', icon: Icons.history),
      const PopupMenuDivider(height: 8),
      menuItem('get', 'Get from Revision', icon: Icons.download_for_offline_outlined, enabled: f.type != ChangeType.deleted),
      menuItem('copy', 'Copy Path', icon: Icons.copy),
    ]);
    if (r == null || !mounted) return;
    switch (r) {
      case 'diff':
        _openDiff(f);
      case 'local':
        ctrl.openTab(DiffTab(DiffRequest(
          title: '${f.fileName} (${c.shortHash} vs Local)',
          leftPath: f.path,
          rightPath: f.path,
          left: CommitRev(c.hash),
          right: const WorkingTreeRev(),
          leftTitle: c.shortHash,
          rightTitle: 'Your version',
        )));
      case 'history':
        ctrl.showHistory(f.path);
      case 'get':
        await ctrl.run('Get ${f.fileName} from ${c.shortHash}',
            () => ctrl.repo.git.run(['checkout', c.hash, '--', f.path], log: true),
            success: '${f.path} restored from ${c.shortHash}');
      case 'copy':
        copyToClipboard(context, f.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _details;
    return Container(
      color: AppColors.panel,
      child: ctrl.selectedCommit.value == null
          ? const EmptyHint('Select a commit to view details')
          : _error != null
              ? EmptyHint('$_error', icon: Icons.error_outline)
              : d == null
                  ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                  : SplitView(
                      axis: Axis.vertical,
                      initialSize: 200,
                      sizeSecond: true,
                      first: _files(d),
                      second: _message(d),
                    ),
    );
  }

  Widget _files(CommitDetails d) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PanelHeader(
          title: '${d.files.length} file${d.files.length == 1 ? '' : 's'} changed',
          actions: [
            if (d.commit.isMerge)
              const Tooltip(
                message: 'Changes shown relative to the first parent',
                child: Icon(Icons.info_outline, size: 14, color: AppColors.textMuted),
              ),
          ],
        ),
        Expanded(
          child: ListView.builder(
            itemCount: d.files.length,
            itemExtent: 24,
            itemBuilder: (context, i) {
              final f = d.files[i];
              return HoverRow(
                selected: _selectedFile == f.path,
                onTap: () {
                  setState(() => _selectedFile = f.path);
                  final c = d.commit;
                  ctrl.showCommitDiff(f, c.hash, c.parents.isEmpty ? null : c.parents.first,
                      preview: true);
                },
                onDoubleTap: () => _openDiff(f),
                onSecondaryTapDown: (e) {
                  setState(() => _selectedFile = f.path);
                  _fileMenu(e.globalPosition, f);
                },
                child: Row(children: [
                  Icon(fileIcon(f.fileName), size: 14, color: changeColor(f.type)),
                  const SizedBox(width: 6),
                  Text(f.fileName, style: TextStyle(fontSize: 13, color: changeColor(f.type))),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      f.oldPath != null ? '← ${f.oldPath}' : f.directory,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                    ),
                  ),
                ]),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _message(CommitDetails d) {
    final c = d.commit;
    const label = TextStyle(fontSize: 12, color: AppColors.textMuted);
    const value = TextStyle(fontSize: 12.5, color: AppColors.textDim);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(10),
      child: SelectionArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(d.body, style: const TextStyle(fontSize: 13, height: 1.4)),
            const SizedBox(height: 12),
            Wrap(children: [for (final r in c.refs) Padding(padding: const EdgeInsets.only(bottom: 4), child: RefChip(r))]),
            const SizedBox(height: 4),
            Row(children: [
              Text(c.hash.substring(0, 10), style: monoStyle(size: 12, color: AppColors.accentHover)),
              const SizedBox(width: 6),
              InkWell(
                onTap: () => copyToClipboard(context, c.hash),
                child: const Icon(Icons.copy, size: 13, color: AppColors.textMuted),
              ),
            ]),
            const SizedBox(height: 4),
            Text.rich(TextSpan(children: [
              TextSpan(text: c.authorName, style: value),
              TextSpan(text: ' <${c.authorEmail}>', style: label),
              const TextSpan(text: ' on ', style: label),
              TextSpan(text: formatDateFull(c.authorTime), style: value),
            ])),
            if (c.committerName != c.authorName)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text.rich(TextSpan(children: [
                  const TextSpan(text: 'committed by ', style: label),
                  TextSpan(text: c.committerName, style: value),
                  const TextSpan(text: ' on ', style: label),
                  TextSpan(text: formatDateFull(c.commitTime), style: value),
                ])),
              ),
            if (c.parents.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '${c.parents.length > 1 ? 'Parents' : 'Parent'}: ${c.parents.map((p) => p.substring(0, 8)).join(', ')}',
                  style: label,
                ),
              ),
            const SizedBox(height: 8),
            if (_containedIn == null)
              const Text('Looking for branches…', style: label)
            else
              Text(
                'In ${_containedIn!.length} branch${_containedIn!.length == 1 ? '' : 'es'}: ${_containedIn!.take(20).join(', ')}${_containedIn!.length > 20 ? ', …' : ''}',
                style: label,
              ),
          ],
        ),
      ),
    );
  }
}
