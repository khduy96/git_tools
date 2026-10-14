/// Status of a file as shown in the Changes view.
enum ChangeType {
  modified,
  added,
  deleted,
  renamed,
  copied,
  typeChanged,
  untracked,
  conflicted,
}

extension ChangeTypeLabel on ChangeType {
  String get letter => switch (this) {
        ChangeType.modified => 'M',
        ChangeType.added => 'A',
        ChangeType.deleted => 'D',
        ChangeType.renamed => 'R',
        ChangeType.copied => 'C',
        ChangeType.typeChanged => 'T',
        ChangeType.untracked => '?',
        ChangeType.conflicted => '!',
      };

  String get label => switch (this) {
        ChangeType.modified => 'Modified',
        ChangeType.added => 'Added',
        ChangeType.deleted => 'Deleted',
        ChangeType.renamed => 'Renamed',
        ChangeType.copied => 'Copied',
        ChangeType.typeChanged => 'Type changed',
        ChangeType.untracked => 'Unversioned',
        ChangeType.conflicted => 'Merge conflict',
      };

  static ChangeType fromLetter(String c) => switch (c) {
        'M' => ChangeType.modified,
        'A' => ChangeType.added,
        'D' => ChangeType.deleted,
        'R' => ChangeType.renamed,
        'C' => ChangeType.copied,
        'T' => ChangeType.typeChanged,
        'U' => ChangeType.conflicted,
        _ => ChangeType.modified,
      };
}

/// A changed file in the working tree (relative to HEAD).
class FileChange {
  const FileChange({
    required this.path,
    required this.type,
    this.oldPath,
    this.staged = false,
    this.unstaged = false,
    this.conflictCode,
  });

  final String path;
  final String? oldPath;
  final ChangeType type;

  /// Whether the index differs from HEAD for this file.
  final bool staged;

  /// Whether the working tree differs from the index for this file.
  final bool unstaged;

  /// Two-letter unmerged code from `git status` (UU, AA, DU, UD, ...).
  final String? conflictCode;

  String get fileName {
    final i = path.lastIndexOf('/');
    return i < 0 ? path : path.substring(i + 1);
  }

  String get directory {
    final i = path.lastIndexOf('/');
    return i < 0 ? '' : path.substring(0, i);
  }

  /// All paths that must be passed to git to commit this change.
  List<String> get allPaths => [path, ?oldPath];

  @override
  bool operator ==(Object other) =>
      other is FileChange && other.path == path && other.type == type;

  @override
  int get hashCode => Object.hash(path, type);
}

enum RepoState { normal, merging, rebasing, cherryPicking, reverting }

class RepoStatus {
  const RepoStatus({
    this.branch,
    this.headHash,
    this.upstream,
    this.ahead = 0,
    this.behind = 0,
    this.changes = const [],
    this.state = RepoState.normal,
  });

  /// Current branch name, or null when HEAD is detached.
  final String? branch;
  final String? headHash;
  final String? upstream;
  final int ahead;
  final int behind;
  final List<FileChange> changes;
  final RepoState state;

  bool get detached => branch == null;
  bool get hasCommits => headHash != null;

  List<FileChange> get tracked => changes
      .where((c) =>
          c.type != ChangeType.untracked && c.type != ChangeType.conflicted)
      .toList();
  List<FileChange> get untracked =>
      changes.where((c) => c.type == ChangeType.untracked).toList();
  List<FileChange> get conflicts =>
      changes.where((c) => c.type == ChangeType.conflicted).toList();
}

class RefLabel {
  const RefLabel(this.name, this.kind);

  final String name;
  final RefKind kind;
}

enum RefKind { head, localBranch, remoteBranch, tag }

class Commit {
  Commit({
    required this.hash,
    required this.parents,
    required this.authorName,
    required this.authorEmail,
    required this.authorTime,
    required this.committerName,
    required this.commitTime,
    required this.subject,
    required this.refs,
  });

  final String hash;
  final List<String> parents;
  final String authorName;
  final String authorEmail;
  final DateTime authorTime;
  final String committerName;
  final DateTime commitTime;
  final String subject;
  final List<RefLabel> refs;

  String get shortHash => hash.substring(0, 8);
  bool get isMerge => parents.length > 1;
}

class CommitDetails {
  const CommitDetails({
    required this.commit,
    required this.body,
    required this.files,
    this.containedIn = const [],
  });

  final Commit commit;
  final String body;
  final List<FileChange> files;
  final List<String> containedIn;
}

class Branch {
  const Branch({
    required this.name,
    required this.isRemote,
    required this.hash,
    this.isCurrent = false,
    this.upstream,
    this.ahead = 0,
    this.behind = 0,
    this.gone = false,
  });

  /// Short name, e.g. `main` or `origin/main`.
  final String name;
  final bool isRemote;
  final String hash;
  final bool isCurrent;
  final String? upstream;
  final int ahead;
  final int behind;
  final bool gone;

  String get remoteName =>
      isRemote ? name.substring(0, name.indexOf('/')) : '';

  /// Branch name without the remote prefix.
  String get shortName =>
      isRemote ? name.substring(name.indexOf('/') + 1) : name;

  bool get isFavorite =>
      const {'main', 'master', 'develop'}.contains(shortName);
}

class Remote {
  const Remote(this.name, this.url);

  final String name;
  final String url;
}

class Tag {
  const Tag(this.name, this.hash);

  final String name;
  final String hash;
}

class Stash {
  const Stash({
    required this.index,
    required this.ref,
    required this.message,
    required this.time,
    required this.hash,
  });

  final int index;
  final String ref;
  final String message;
  final DateTime time;
  final String hash;
}

/// Where one side of a diff comes from.
sealed class Revision {
  const Revision();
}

class WorkingTreeRev extends Revision {
  const WorkingTreeRev();
}

class IndexRev extends Revision {
  const IndexRev();
}

class CommitRev extends Revision {
  const CommitRev(this.hash);
  final String hash;
}

class EmptyRev extends Revision {
  const EmptyRev();
}

/// What to show in the diff viewer.
class DiffRequest {
  const DiffRequest({
    required this.title,
    required this.leftPath,
    required this.rightPath,
    required this.left,
    required this.right,
    this.leftTitle = '',
    this.rightTitle = '',
  });

  final String title;
  final String leftPath;
  final String rightPath;
  final Revision left;
  final Revision right;
  final String leftTitle;
  final String rightTitle;

  String get key => '$leftPath|$rightPath|${_revKey(left)}|${_revKey(right)}';

  static String _revKey(Revision r) => switch (r) {
        WorkingTreeRev() => 'wt',
        IndexRev() => 'idx',
        CommitRev(:final hash) => hash,
        EmptyRev() => 'empty',
      };
}

class BlameLine {
  const BlameLine({
    required this.hash,
    required this.author,
    required this.time,
    required this.summary,
    required this.text,
  });

  final String hash;
  final String author;
  final DateTime time;
  final String summary;
  final String text;
}
