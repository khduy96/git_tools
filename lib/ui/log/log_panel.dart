import 'package:flutter/material.dart';

import '../../state/repo_controller.dart';
import '../widgets/split_view.dart';
import 'branches_tree.dart';
import 'commit_details.dart';
import 'commit_table.dart';

/// The "Log" tab of the Git tool window.
class LogPanel extends StatelessWidget {
  const LogPanel({super.key, required this.controller});

  final RepoController controller;

  @override
  Widget build(BuildContext context) {
    return SplitView(
      axis: Axis.horizontal,
      initialSize: 230,
      first: BranchesTree(controller: controller),
      second: SplitView(
        axis: Axis.horizontal,
        initialSize: 380,
        sizeSecond: true,
        minSize: 200,
        first: CommitTable(controller: controller),
        second: CommitDetailsPanel(controller: controller),
      ),
    );
  }
}
