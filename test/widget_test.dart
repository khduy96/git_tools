import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:git_tools/git/conflict_parser.dart';
import 'package:git_tools/git/git_repository.dart';
import 'package:git_tools/git/graph_layout.dart';
import 'package:git_tools/git/models.dart';
import 'package:git_tools/git/text_diff.dart';
import 'package:path/path.dart' as p;

Commit _c(String h, List<String> parents) => Commit(
      hash: h.padRight(40, '0'),
      parents: parents.map((x) => x.padRight(40, '0')).toList(),
      authorName: 'a',
      authorEmail: 'a@a',
      authorTime: DateTime(2024),
      committerName: 'a',
      commitTime: DateTime(2024),
      subject: h,
      refs: const [],
    );

void main() {
  group('text diff', () {
    test('identical texts have no blocks', () {
      expect(TextDiff.compute('a\nb\n', 'a\nb\n').identical, isTrue);
    });

    test('detects modify, insert and delete', () {
      final d = TextDiff.compute('a\nb\nc\nd\n', 'a\nB\nc\nd\ne\n');
      expect(d.blocks.length, 2);
      expect(d.blocks[0].kind, DiffKind.modified);
      expect((d.blocks[0].aStart, d.blocks[0].bStart), (1, 1));
      expect(d.blocks[1].kind, DiffKind.inserted);
      expect(d.insertedLines, 2);
      expect(d.deletedLines, 1);
    });

    test('pure deletion in the middle', () {
      final d = TextDiff.compute('1\n2\n3\n4\n5\n', '1\n2\n5\n');
      expect(d.blocks.single.kind, DiffKind.deleted);
      expect((d.blocks.single.aStart, d.blocks.single.aEnd), (2, 4));
    });

    test('CRLF and LF compare equal', () {
      expect(TextDiff.compute('a\r\nb\r\n', 'a\nb\n').identical, isTrue);
    });

    test('ignore whitespace', () {
      expect(TextDiff.compute('a  b\n', 'a b\n', ignoreWhitespace: true).identical, isTrue);
    });

    test('random edits reconstruct the right side', () {
      final left = List.generate(300, (i) => 'line ${i % 37}');
      final right = [...left]
        ..removeRange(10, 20)
        ..insertAll(50, ['x', 'y'])
        ..[100] = 'changed'
        ..addAll(['tail']);
      final d = TextDiff.compute('${left.join('\n')}\n', '${right.join('\n')}\n');
      // Apply blocks to left and compare with right.
      final out = <String>[];
      var ai = 0;
      for (final b in d.blocks) {
        out.addAll(left.sublist(ai, b.aStart));
        out.addAll(right.sublist(b.bStart, b.bEnd));
        ai = b.aEnd;
      }
      out.addAll(left.sublist(ai));
      expect(out, right);
    });

    test('side-by-side rows collapse unchanged regions', () {
      final left = List.generate(100, (i) => 'l$i').join('\n');
      final right = left.replaceFirst('l50', 'X');
      final rows = buildSideRows(TextDiff.compute(left, right));
      expect(rows.where((r) => r.isFold).length, 2);
      expect(rows.where((r) => r.kind == DiffKind.modified).length, 1);
    });

    test('intraline highlights changed word', () {
      final (l, r) = intraline('final a = 1;', 'final a = 2;');
      expect(l.single.start, 10);
      expect(r.single.end, 11);
    });
  });

  group('graph layout', () {
    test('linear history uses a single lane', () {
      final rows = layoutGraph([_c('c', ['b']), _c('b', ['a']), _c('a', [])]);
      expect(rows.map((r) => r.lane), [0, 0, 0]);
    });

    test('merge opens and closes a second lane', () {
      // m merges x (lane 1) into main.
      final rows = layoutGraph([
        _c('m', ['b', 'x']),
        _c('x', ['a']),
        _c('b', ['a']),
        _c('a', []),
      ]);
      expect(rows[0].lane, 0);
      expect(rows[1].lane, 1);
      expect(rows[2].lane, 0);
      expect(rows[3].lane, 0);
      expect(rows[3].segments.where((s) => s.part == SegmentPart.top).length, 2);
    });
  });

  group('conflict parser', () {
    test('parses diff3 conflicts and joins resolution', () {
      const text = 'top\n<<<<<<< ours\nA\n||||||| base\nO\n=======\nB\n>>>>>>> theirs\nbottom\n';
      final segs = parseConflicts(text);
      expect(segs.length, 3);
      final c = segs[1] as ConflictSegment;
      expect(c.ours, ['A']);
      expect(c.base, ['O']);
      expect(c.theirs, ['B']);
      c.choice = ConflictChoice.oursThenTheirs;
      expect(joinSegments(segs), 'top\nA\nB\nbottom\n');
    });
  });

  group('git repository', () {
    late Directory dir;
    late GitRepository repo;

    Future<void> git(List<String> args) async {
      final r = await Process.run('git', args, workingDirectory: dir.path);
      if (r.exitCode != 0) fail('git ${args.join(' ')}: ${r.stderr}');
    }

    void write(String name, String content) {
      final f = File(p.join(dir.path, name));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(content);
    }

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('git_tools_test');
      await git(['init', '-q', '-b', 'main']);
      await git(['config', 'user.name', 'Test']);
      await git(['config', 'user.email', 'test@example.com']);
      await git(['config', 'core.autocrlf', 'false']);
      repo = GitRepository(dir.path);
    });

    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    test('status of a fresh repository', () async {
      write('a.txt', 'hello\n');
      write('dir with space/b.txt', 'b\n');
      final s = await repo.status();
      expect(s.hasCommits, isFalse);
      expect(s.branch, 'main');
      expect(s.untracked.map((c) => c.path), ['a.txt', 'dir with space/b.txt']);
    });

    test('partial commit only commits selected files', () async {
      write('a.txt', 'a\n');
      write('b.txt', 'b\n');
      await repo.commit(message: 'first', paths: ['a.txt']);
      var s = await repo.status();
      expect(s.hasCommits, isTrue);
      expect(s.untracked.map((c) => c.path), ['b.txt']);

      write('a.txt', 'a2\n');
      await repo.commit(message: 'second', paths: ['b.txt']);
      s = await repo.status();
      expect(s.tracked.single.path, 'a.txt');
      expect(s.tracked.single.type, ChangeType.modified);

      final log = await repo.log();
      expect(log.map((c) => c.subject), ['second', 'first']);
      expect(log.first.refs.any((r) => r.kind == RefKind.head), isTrue);
      final files = await repo.changedFiles(log.first.parents.first, log.first.hash);
      expect(files.single.path, 'b.txt');
      expect(files.single.type, ChangeType.added);
    });

    test('partial commit with glob characters in file names', () async {
      write('app/[id].tsx', 'x\n');
      write('app/i.tsx', 'i\n');
      await repo.commit(message: 'only bracket file', paths: ['app/[id].tsx']);
      final s = await repo.status();
      expect(s.untracked.map((c) => c.path), ['app/i.tsx']);
    });

    test('rename, delete and rollback', () async {
      write('a.txt', 'content of a that is long enough\n');
      write('d.txt', 'delete me\n');
      await repo.commit(message: 'init', paths: ['a.txt', 'd.txt']);
      await git(['mv', 'a.txt', 'renamed.txt']);
      File(p.join(dir.path, 'd.txt')).deleteSync();
      var s = await repo.status();
      final renamed = s.tracked.firstWhere((c) => c.type == ChangeType.renamed);
      expect((renamed.oldPath, renamed.path), ('a.txt', 'renamed.txt'));
      expect(s.tracked.any((c) => c.type == ChangeType.deleted && c.path == 'd.txt'), isTrue);

      await repo.rollback(s.tracked, hasHead: true);
      s = await repo.status();
      expect(s.changes.where((c) => c.type != ChangeType.untracked), isEmpty);
      expect(File(p.join(dir.path, 'd.txt')).existsSync(), isTrue);
    });

    test('branches, merge conflict and resolution', () async {
      write('f.txt', 'base\n');
      await repo.commit(message: 'base', paths: ['f.txt']);
      await repo.createBranch('feature');
      write('f.txt', 'feature\n');
      await repo.commit(message: 'feature change', paths: ['f.txt']);
      await repo.checkout('main');
      write('f.txt', 'main\n');
      await repo.commit(message: 'main change', paths: ['f.txt']);

      final branches = await repo.branches();
      expect(branches.map((b) => b.name).toSet(), {'main', 'feature'});
      expect(branches.firstWhere((b) => b.isCurrent).name, 'main');

      await expectLater(repo.merge('feature'), throwsA(anything));
      var s = await repo.status();
      expect(s.state, RepoState.merging);
      expect(s.conflicts.single.conflictCode, 'UU');

      final text = File(p.join(dir.path, 'f.txt')).readAsStringSync();
      final segs = parseConflicts(text);
      final c = segs.whereType<ConflictSegment>().single;
      expect(c.ours, ['main']);
      expect(c.theirs, ['feature']);
      c.choice = ConflictChoice.theirs;
      await repo.markResolved('f.txt', joinSegments(segs));
      s = await repo.status();
      expect(s.conflicts, isEmpty);
      await repo.continueOperation(RepoState.merging);
      s = await repo.status();
      expect(s.state, RepoState.normal);
      final log = await repo.log();
      expect(log.first.isMerge, isTrue);
      expect(layoutGraph(log).first.segments.where((x) => x.part == SegmentPart.bottom).length, 2);
    });

    test('stash push, list, files and pop', () async {
      write('f.txt', '1\n');
      await repo.commit(message: 'base', paths: ['f.txt']);
      write('f.txt', '2\n');
      write('new.txt', 'n\n');
      await repo.stash(message: 'wip', includeUntracked: true);
      expect((await repo.status()).changes, isEmpty);
      final stashes = await repo.stashes();
      expect(stashes.single.message, contains('wip'));
      final files = await repo.stashFiles(stashes.single);
      expect(files.map((f) => f.path).toSet(), {'f.txt', 'new.txt'});
      await repo.stashApply(stashes.single, pop: true);
      expect((await repo.status()).changes.length, 2);
      expect(await repo.stashes(), isEmpty);
    });

    test('blame and file content at revisions', () async {
      write('f.txt', 'one\ntwo\n');
      await repo.commit(message: 'base', paths: ['f.txt']);
      write('f.txt', 'one\nTWO\n');
      final blame = await repo.blame('f.txt');
      expect(blame.length, 2);
      expect(blame[0].author, 'Test');
      final head = await repo.fileBytes(const CommitRev('HEAD'), 'f.txt');
      expect(String.fromCharCodes(head!), 'one\ntwo\n');
      final wt = await repo.fileBytes(const WorkingTreeRev(), 'f.txt');
      expect(String.fromCharCodes(wt!), 'one\nTWO\n');
    });
  });
}
