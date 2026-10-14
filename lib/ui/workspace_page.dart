import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../git/models.dart';
import '../state/app_settings.dart';
import '../state/repo_controller.dart';
import 'actions.dart';
import 'branches/branches_popup.dart';
import 'commit/commit_panel.dart';
import 'common.dart';
import 'console/console_panel.dart';
import 'diff/blame_view.dart';
import 'diff/lines_view.dart';
import 'diff/diff_view.dart';
import 'dialogs/ai_settings_dialog.dart';
import 'dialogs/ai_setup_guide.dart';
import 'dialogs/basic_dialogs.dart';
import 'dialogs/pull_dialog.dart';
import 'dialogs/push_dialog.dart';
import 'dialogs/remotes_dialog.dart';
import 'dialogs/stash_dialogs.dart';
import 'log/log_panel.dart';
import 'widgets/split_view.dart';

class WorkspacePage extends StatefulWidget {
  const WorkspacePage({
    super.key,
    required this.controller,
    required this.settings,
    required this.onOpenRepo,
    required this.onCloneRepo,
    required this.onSwitchRepo,
    required this.onClose,
  });

  final RepoController controller;
  final AppSettings settings;
  final VoidCallback onOpenRepo;
  final VoidCallback onCloneRepo;
  final void Function(String path) onSwitchRepo;
  final VoidCallback onClose;

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage> {
  RepoController get ctrl => widget.controller;

  bool _showCommit = true;
  bool _showBottom = true;
  final _messageFocus = FocusNode();
  final _branchKey = GlobalKey();
  final _rootFocus = FocusNode();
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    ctrl.notifications.addListener(_onNotification);
    ctrl.bottomTab.addListener(_onBottomTab);
    _lifecycle = AppLifecycleListener(onResume: () => ctrl.refreshAll());
  }

  @override
  void dispose() {
    ctrl.notifications.removeListener(_onNotification);
    ctrl.bottomTab.removeListener(_onBottomTab);
    _lifecycle.dispose();
    _messageFocus.dispose();
    _rootFocus.dispose();
    super.dispose();
  }

  void _onBottomTab() {
    if (!_showBottom) setState(() => _showBottom = true);
  }

  void _onNotification() {
    final n = ctrl.notifications.value;
    if (n == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      width: 460,
      backgroundColor: AppColors.panel,
      duration: Duration(seconds: n.isError ? 8 : 3),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: n.isError ? AppColors.error.withValues(alpha: 0.6) : AppColors.border),
      ),
      content: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            n.isError ? Icons.error_outline : Icons.check_circle_outline,
            size: 18,
            color: n.isError ? AppColors.error : AppColors.success,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(n.title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.text)),
                if (n.details != null && n.details!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      n.details!,
                      maxLines: 8,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: AppColors.textDim),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      action: n.isError
          ? SnackBarAction(
              label: 'Console',
              textColor: AppColors.accentHover,
              onPressed: () => ctrl.bottomTab.value = 1,
            )
          : null,
    ));
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  void _focusCommit() {
    setState(() => _showCommit = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _messageFocus.requestFocus());
  }

  void _push() => showPushDialog(context, ctrl);

  void _update() => showPullDialog(context, ctrl, widget.settings);

  void _fetch() => ctrl.run('Fetch', () => ctrl.repo.fetch(), success: 'Fetched all remotes');

  Future<void> _checkoutRevision() async {
    final ref = await showInput(context,
        title: 'Checkout Tag or Revision',
        label: 'Enter a branch, tag or commit hash:',
        confirmLabel: 'Checkout');
    if (ref == null || ref.trim().isEmpty || !mounted) return;
    final r = ref.trim();
    if (!await ctrl.repo.refExists('$r^{commit}')) {
      ctrl.notify(AppNotification('Unknown revision', details: r, isError: true));
      return;
    }
    if (mounted) await smartCheckout(context, ctrl, 'Checkout $r', () => ctrl.repo.checkout(r));
  }

  void _branchesPopup() {
    final box = _branchKey.currentContext?.findRenderObject() as RenderBox?;
    final pos = box == null ? const Offset(200, 40) : box.localToGlobal(Offset(0, box.size.height + 4));
    showBranchesPopup(
      context,
      ctrl,
      pos,
      BranchPopupActions(
        update: _update,
        commit: _focusCommit,
        push: _push,
        newBranch: () => newBranchDialog(context, ctrl),
        checkoutRevision: _checkoutRevision,
      ),
    );
  }

  Future<void> _gitMenu(Offset pos) async {
    final r = await showContextMenu<String>(context, pos, [
      menuItem('commit', 'Commit…', icon: Icons.check, shortcut: 'Ctrl+K'),
      menuItem('push', 'Push…', icon: Icons.upload, shortcut: 'Ctrl+Shift+K'),
      menuItem('update', 'Update Project / Pull…', icon: Icons.download, shortcut: 'Ctrl+T'),
      menuItem('fetch', 'Fetch', icon: Icons.sync),
      const PopupMenuDivider(height: 8),
      menuItem('branches', 'Branches…', icon: Icons.call_split, shortcut: 'Ctrl+Shift+`'),
      menuItem('newBranch', 'New Branch…', icon: Icons.add),
      menuItem('checkoutRev', 'Checkout Tag or Revision…', icon: Icons.sell_outlined),
      const PopupMenuDivider(height: 8),
      menuItem('stash', 'Stash Changes…', icon: Icons.inventory_2_outlined),
      menuItem('unstash', 'Unstash Changes…', icon: Icons.unarchive_outlined),
      const PopupMenuDivider(height: 8),
      menuItem('remotes', 'Manage Remotes…', icon: Icons.cloud_outlined),
      menuItem('ai', 'AI Commit Message Settings…', icon: Icons.auto_awesome),
      menuItem('aiGuide', 'AI Setup Guide', icon: Icons.menu_book_outlined),
      menuItem('explorer', 'Open in Explorer', icon: Icons.folder_open_outlined),
      menuItem('terminal', 'Open Terminal Here', icon: Icons.terminal),
      const PopupMenuDivider(height: 8),
      menuItem('close', 'Close Repository', icon: Icons.logout),
    ]);
    if (!mounted) return;
    switch (r) {
      case 'commit':
        _focusCommit();
      case 'push':
        _push();
      case 'update':
        _update();
      case 'fetch':
        _fetch();
      case 'branches':
        _branchesPopup();
      case 'newBranch':
        newBranchDialog(context, ctrl);
      case 'checkoutRev':
        _checkoutRevision();
      case 'stash':
        showStashDialog(context, ctrl);
      case 'unstash':
        ctrl.bottomTab.value = 2;
      case 'remotes':
        showRemotesDialog(context, ctrl);
      case 'ai':
        showAiSettingsDialog(context, widget.settings).then((_) => setState(() {}));
      case 'aiGuide':
        showAiSetupGuide(context, initial: widget.settings.aiProvider);
      case 'explorer':
        openFolder(ctrl.root);
      case 'terminal':
        openTerminal(ctrl.root);
      case 'close':
        widget.onClose();
    }
  }

  Future<void> _repoMenu(Offset pos) async {
    final recent = widget.settings.recentRepos.where((r) => r != ctrl.root).take(10).toList();
    final r = await showContextMenu<String>(context, pos, [
      menuItem('__open', 'Open…', icon: Icons.folder_open),
      menuItem('__clone', 'Clone…', icon: Icons.download),
      menuItem('__close', 'Close Repository', icon: Icons.logout),
      if (recent.isNotEmpty) const PopupMenuDivider(height: 8),
      for (final path in recent) menuItem(path, p.basename(path), icon: Icons.folder_special_outlined),
    ]);
    switch (r) {
      case null:
        return;
      case '__open':
        widget.onOpenRepo();
      case '__clone':
        widget.onCloneRepo();
      case '__close':
        widget.onClose();
      default:
        widget.onSwitchRepo(r);
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): _focusCommit,
        const SingleActivator(LogicalKeyboardKey.keyK, control: true, shift: true): _push,
        const SingleActivator(LogicalKeyboardKey.keyT, control: true): _update,
        const SingleActivator(LogicalKeyboardKey.f5): () => ctrl.refreshAll(),
        const SingleActivator(LogicalKeyboardKey.digit0, alt: true): () => setState(() => _showCommit = !_showCommit),
        const SingleActivator(LogicalKeyboardKey.digit9, alt: true): () => setState(() => _showBottom = !_showBottom),
        const SingleActivator(LogicalKeyboardKey.backquote, control: true, shift: true): _branchesPopup,
        const SingleActivator(LogicalKeyboardKey.f4, control: true): _closeActiveTab,
        const SingleActivator(LogicalKeyboardKey.keyW, control: true): _closeActiveTab,
      },
      child: Focus(
        focusNode: _rootFocus,
        autofocus: true,
        child: Scaffold(
          backgroundColor: AppColors.background,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _topBar(),
              const Divider(),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _stripe(),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: SplitView(
                        axis: Axis.vertical,
                        sizeSecond: true,
                        initialSize: 330,
                        minSize: 120,
                        showSecond: _showBottom,
                        first: SplitView(
                          axis: Axis.horizontal,
                          initialSize: 400,
                          minSize: 240,
                          showFirst: _showCommit,
                          first: CommitPanel(
                            controller: ctrl,
                            settings: widget.settings,
                            messageFocus: _messageFocus,
                          ),
                          second: _editorArea(),
                        ),
                        second: _bottomWindow(),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(),
              _statusBar(),
            ],
          ),
        ),
      ),
    );
  }

  void _closeActiveTab() {
    final k = ctrl.activeTab.value;
    if (k != null) ctrl.closeTab(k);
  }

  Widget _topBar() {
    return Container(
      height: 40,
      color: AppColors.panel,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Builder(builder: (bctx) {
            return ToolButton(
              icon: Icons.menu,
              tooltip: 'Git Menu',
              size: 18,
              onPressed: () {
                final box = bctx.findRenderObject() as RenderBox;
                _gitMenu(box.localToGlobal(Offset(0, box.size.height + 4)));
              },
            );
          }),
          const SizedBox(width: 6),
          Builder(builder: (bctx) {
            return _TopWidget(
              onTap: () {
                final box = bctx.findRenderObject() as RenderBox;
                _repoMenu(box.localToGlobal(Offset(0, box.size.height + 4)));
              },
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.graph[ctrl.name.hashCode.abs() % AppColors.graph.length].withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    ctrl.name.substring(0, ctrl.name.length >= 2 ? 2 : 1).toUpperCase(),
                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                ),
                const SizedBox(width: 8),
                Text(ctrl.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const Icon(Icons.expand_more, size: 16, color: AppColors.textDim),
              ]),
            );
          }),
          const SizedBox(width: 4),
          ValueListenableBuilder<RepoStatus>(
            valueListenable: ctrl.status,
            builder: (context, s, _) => _TopWidget(
              key: _branchKey,
              onTap: _branchesPopup,
              tooltip: s.upstream == null ? 'No upstream branch' : 'Tracking ${s.upstream}',
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.call_split, size: 16, color: AppColors.textDim),
                const SizedBox(width: 6),
                Text(
                  s.branch ?? (s.headHash != null ? 'Detached ${s.headHash!.substring(0, 8)}' : 'No commits'),
                  style: const TextStyle(fontSize: 13),
                ),
                if (s.ahead > 0) ...[
                  const SizedBox(width: 6),
                  Text('↑${s.ahead}', style: const TextStyle(fontSize: 12, color: AppColors.added)),
                ],
                if (s.behind > 0) ...[
                  const SizedBox(width: 4),
                  Text('↓${s.behind}', style: const TextStyle(fontSize: 12, color: AppColors.modified)),
                ],
                const Icon(Icons.expand_more, size: 16, color: AppColors.textDim),
              ]),
            ),
          ),
          const Spacer(),
          ValueListenableBuilder<String?>(
            valueListenable: ctrl.busy,
            builder: (_, busy, _) => Row(children: [
              ToolButton(
                icon: Icons.south_west,
                tooltip: 'Update Project… (Ctrl+T)',
                color: AppColors.modified,
                size: 18,
                onPressed: busy == null ? _update : null,
              ),
              ToolButton(
                icon: Icons.check,
                tooltip: 'Commit… (Ctrl+K)',
                color: AppColors.success,
                size: 18,
                onPressed: _focusCommit,
              ),
              ToolButton(
                icon: Icons.north_east,
                tooltip: 'Push… (Ctrl+Shift+K)',
                color: AppColors.success,
                size: 18,
                onPressed: busy == null ? _push : null,
              ),
              ToolButton(
                icon: Icons.sync,
                tooltip: 'Fetch',
                size: 18,
                onPressed: busy == null ? _fetch : null,
              ),
              const SizedBox(width: 4),
              ToolButton(
                icon: Icons.history,
                tooltip: 'Show Git Log (Alt+9)',
                size: 18,
                onPressed: () {
                  ctrl.bottomTab.value = 0;
                  setState(() => _showBottom = true);
                },
              ),
              ToolButton(
                icon: Icons.refresh,
                tooltip: 'Refresh (F5)',
                size: 18,
                onPressed: () => ctrl.refreshAll(),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _stripe() {
    Widget item(IconData icon, String tip, bool active, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Tooltip(
            message: tip,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(6),
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: active ? AppColors.selection : null,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(icon, size: 18, color: active ? AppColors.text : AppColors.textDim),
              ),
            ),
          ),
        );
    return Container(
      width: 40,
      color: AppColors.panel,
      child: Column(children: [
        const SizedBox(height: 4),
        item(Icons.check_box_outlined, 'Commit (Alt+0)', _showCommit, () => setState(() => _showCommit = !_showCommit)),
        const Spacer(),
        item(Icons.account_tree_outlined, 'Git (Alt+9)', _showBottom, () => setState(() => _showBottom = !_showBottom)),
        const SizedBox(height: 4),
      ]),
    );
  }

  Widget _editorArea() {
    return ListenableBuilder(
      listenable: Listenable.merge([ctrl.tabs, ctrl.activeTab, ctrl.previewTab]),
      builder: (context, _) {
        final tabs = ctrl.tabs.value;
        if (tabs.isEmpty) return _emptyEditor();
        final active = ctrl.activeTab.value;
        final index = tabs.indexWhere((t) => t.key == active).clamp(0, tabs.length - 1);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 34,
              color: AppColors.panel,
              child: Row(children: [
                Expanded(
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (var i = 0; i < tabs.length; i++)
                        _EditorTabButton(
                          tab: tabs[i],
                          active: i == index,
                          preview: tabs[i].key == ctrl.previewTab.value,
                          onTap: () => ctrl.activeTab.value = tabs[i].key,
                          onClose: () => ctrl.closeTab(tabs[i].key),
                          onMenu: (pos) async {
                            final r = await showContextMenu<String>(context, pos, [
                              menuItem('close', 'Close', shortcut: 'Ctrl+F4'),
                              menuItem('others', 'Close Other Tabs'),
                              menuItem('all', 'Close All Tabs'),
                            ]);
                            switch (r) {
                              case 'close':
                                ctrl.closeTab(tabs[i].key);
                              case 'others':
                                for (final t in tabs) {
                                  if (t.key != tabs[i].key) ctrl.closeTab(t.key);
                                }
                              case 'all':
                                ctrl.closeAllTabs();
                            }
                          },
                        ),
                    ],
                  ),
                ),
              ]),
            ),
            const Divider(),
            Expanded(
              child: IndexedStack(
                index: index,
                children: [
                  for (final t in tabs)
                    KeyedSubtree(
                      key: ValueKey(t.key),
                      child: switch (t) {
                        DiffTab(:final request) => DiffView(
                            controller: ctrl,
                            request: request,
                            settings: widget.settings,
                          ),
                        BlameTab(:final path) => BlameView(controller: ctrl, path: path),
                        LinesTab(:final path) => LinesView(controller: ctrl, path: path),
                      },
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _emptyEditor() {
    Widget hint(String action, String keys) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
              width: 200,
              child: Text(action, textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, color: AppColors.textDim)),
            ),
            const SizedBox(width: 14),
            SizedBox(
              width: 160,
              child: Text(keys, style: const TextStyle(fontSize: 13, color: AppColors.accentHover)),
            ),
          ]),
        );
    return Container(
      color: AppColors.background,
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          hint('Commit', 'Ctrl+K'),
          hint('Push', 'Ctrl+Shift+K'),
          hint('Update Project', 'Ctrl+T'),
          hint('Branches', 'Ctrl+Shift+`'),
          hint('Show Diff (in Changes)', 'Ctrl+D'),
          hint('Next / Previous Difference', 'F7 / Shift+F7'),
          hint('Commit / Git tool window', 'Alt+0 / Alt+9'),
          hint('Refresh', 'F5'),
        ]),
      ),
    );
  }

  Widget _bottomWindow() {
    return Container(
      color: AppColors.panel,
      child: ValueListenableBuilder<int>(
        valueListenable: ctrl.bottomTab,
        builder: (context, tab, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(children: [
                const Text('Git', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(width: 12),
                _BottomTab('Log', tab == 0, () => ctrl.bottomTab.value = 0),
                _BottomTab('Console', tab == 1, () => ctrl.bottomTab.value = 1),
                ValueListenableBuilder<List<Stash>>(
                  valueListenable: ctrl.stashes,
                  builder: (_, s, _) => _BottomTab(
                      s.isEmpty ? 'Stashes' : 'Stashes (${s.length})', tab == 2, () => ctrl.bottomTab.value = 2),
                ),
                const Spacer(),
                ToolButton(
                  icon: Icons.remove,
                  tooltip: 'Hide (Alt+9)',
                  onPressed: () => setState(() => _showBottom = false),
                ),
              ]),
            ),
            const Divider(),
            Expanded(
              child: IndexedStack(
                index: tab,
                children: [
                  LogPanel(controller: ctrl),
                  ConsolePanel(controller: ctrl),
                  StashesPanel(controller: ctrl),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusBar() {
    return Container(
      height: 26,
      color: AppColors.panel,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(children: [
        ValueListenableBuilder<String?>(
          valueListenable: ctrl.busy,
          builder: (_, busy, _) => busy == null
              ? Text(ctrl.root, style: const TextStyle(fontSize: 12, color: AppColors.textMuted))
              : Row(children: [
                  const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
                  const SizedBox(width: 8),
                  Text('$busy…', style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
                ]),
        ),
        const Spacer(),
        ValueListenableBuilder<RepoStatus>(
          valueListenable: ctrl.status,
          builder: (_, s, _) => Row(children: [
            if (s.changes.isNotEmpty)
              Text('${s.changes.length} change${s.changes.length == 1 ? '' : 's'}',
                  style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
            const SizedBox(width: 14),
            InkWell(
              onTap: _branchesPopup,
              child: Row(children: [
                const Icon(Icons.call_split, size: 13, color: AppColors.textDim),
                const SizedBox(width: 4),
                Text(s.branch ?? 'detached', style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _TopWidget extends StatelessWidget {
  const _TopWidget({super.key, required this.child, required this.onTap, this.tooltip});

  final Widget child;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final w = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(5),
      hoverColor: AppColors.hover,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: child,
      ),
    );
    return tooltip == null ? w : Tooltip(message: tooltip!, child: w);
  }
}

class _BottomTab extends StatelessWidget {
  const _BottomTab(this.label, this.active, this.onTap);

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: active ? AppColors.accent : Colors.transparent, width: 2),
          ),
        ),
        alignment: Alignment.center,
        child: Text(label,
            style: TextStyle(fontSize: 13, color: active ? AppColors.text : AppColors.textDim)),
      ),
    );
  }
}

class _EditorTabButton extends StatefulWidget {
  const _EditorTabButton({
    required this.tab,
    required this.active,
    required this.preview,
    required this.onTap,
    required this.onClose,
    required this.onMenu,
  });

  final EditorTab tab;
  final bool active;
  final bool preview;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final void Function(Offset) onMenu;

  @override
  State<_EditorTabButton> createState() => _EditorTabButtonState();
}

class _EditorTabButtonState extends State<_EditorTabButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Listener(
        onPointerDown: (e) {
          if (e.buttons == kMiddleMouseButton) widget.onClose();
        },
        child: GestureDetector(
          onTap: widget.onTap,
          onSecondaryTapDown: (d) => widget.onMenu(d.globalPosition),
          child: Container(
            padding: const EdgeInsets.only(left: 10, right: 4),
            decoration: BoxDecoration(
              color: widget.active ? AppColors.background : (_hover ? AppColors.hover.withValues(alpha: 0.4) : null),
              border: Border(
                bottom: BorderSide(color: widget.active ? AppColors.accent : Colors.transparent, width: 2),
              ),
            ),
            child: Row(children: [
              Icon(
                switch (widget.tab) {
                  BlameTab() => Icons.person_search_outlined,
                  LinesTab() => Icons.checklist,
                  DiffTab() => Icons.difference_outlined,
                },
                size: 14,
                color: AppColors.textDim,
              ),
              const SizedBox(width: 6),
              Text(
                widget.tab.title,
                style: TextStyle(
                  fontSize: 12.5,
                  fontStyle: widget.preview ? FontStyle.italic : null,
                  color: widget.active ? AppColors.text : AppColors.textDim,
                ),
              ),
              const SizedBox(width: 4),
              Opacity(
                opacity: _hover || widget.active ? 1 : 0,
                child: InkWell(
                  onTap: widget.onClose,
                  borderRadius: BorderRadius.circular(3),
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(Icons.close, size: 13, color: AppColors.textDim),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
