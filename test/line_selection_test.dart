import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:git_tools/git/git_repository.dart';
import 'package:git_tools/git/line_selection.dart';
import 'package:path/path.dart' as p;

/// Real `git diff --no-index` between two texts.
String gitDiff(String oldText, String newText, {int context = 3}) {
  final dir = Directory.systemTemp.createTempSync('gt_ls_');
  try {
    File(p.join(dir.path, 'a')).writeAsStringSync(oldText);
    File(p.join(dir.path, 'b')).writeAsStringSync(newText);
    final r = Process.runSync('git', ['-c', 'core.autocrlf=false', 'diff', '--no-index', '--no-color', '-U$context', 'a', 'b'],
        workingDirectory: dir.path);
    return r.stdout as String;
  } finally {
    dir.deleteSync(recursive: true);
  }
}

({ParsedDiff parsed, Set<String> excluded, String content}) applySel(
    String oldText, String newText, bool Function(DiffLineEntry l) pick, {int context = 3}) {
  final parsed = parseDiff(gitDiff(oldText, newText, context: context));
  final excluded = <String>{};
  for (var i = 0; i < parsed.hunks.length; i++) {
    for (var j = 0; j < parsed.hunks[i].lines.length; j++) {
      final l = parsed.hunks[i].lines[j];
      if (l.isChange && !pick(l)) excluded.add(lineKey(i, j));
    }
  }
  return (parsed: parsed, excluded: excluded, content: buildContent(oldText, parsed, excluded));
}

final old = [for (final x in 'abcdefghijkl'.split('')) '$x\n'].join();

void main() {
  group('buildContent', () {
    test('all / none selected', () {
      final newText = old.replaceFirst('b\n', 'B\n').replaceFirst('k\n', 'k\nk2\n').replaceFirst('f\n', '');
      for (final ctx in [0, 3]) {
        expect(applySel(old, newText, (_) => true, context: ctx).content, newText);
        expect(applySel(old, newText, (_) => false, context: ctx).content, old);
      }
    });

    test('single changes', () {
      final newText = old.replaceFirst('b\n', 'B\n').replaceFirst('k\n', 'k\nk2\n').replaceFirst('f\n', '');
      expect(applySel(old, newText, (l) => l.text == 'k2').content, old.replaceFirst('k\n', 'k\nk2\n'));
      expect(applySel(old, newText, (l) => l.kind == '-' && l.text == 'f').content, old.replaceFirst('f\n', ''));
      expect(applySel(old, newText, (l) => l.text == 'b').content, old.replaceFirst('b\n', ''));
    });

    test('top / end insertions and missing newline at EOF', () {
      final newText = 'top\n${old}end';
      expect(applySel(old, newText, (_) => true).content, newText);
      expect(applySel(old, newText, (l) => l.text == 'top').content, 'top\n$old');
      expect(applySel(old, newText, (l) => l.text == 'end').content, '${old}end');
      expect(applySel('x\ny', 'x\ny\nz\n', (_) => true).content, 'x\ny\nz\n');
      expect(applySel('x\ny', 'x\ny\nz\n', (_) => false).content, 'x\ny');
    });

    test('random edits match git apply of the filtered patch', () {
      var seed = 7;
      double rnd() => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648;
      for (var round = 0; round < 30; round++) {
        final oldLines = [for (var i = 0; i < 30; i++) 'line $i ${(rnd() * 5).floor()}'];
        final newLines = <String>[];
        for (final l in oldLines) {
          final r = rnd();
          if (r < 0.15) continue;
          newLines.add(r < 0.3 ? '$l changed' : l);
          if (rnd() < 0.1) newLines.add('inserted $round');
        }
        final oldText = '${oldLines.join('\n')}\n';
        final newText = '${newLines.join('\n')}\n';
        final s = applySel(oldText, newText, (_) => rnd() < 0.5);
        final dir = Directory.systemTemp.createTempSync('gt_ls_apply_');
        try {
          File(p.join(dir.path, 'f')).writeAsStringSync(oldText);
          File(p.join(dir.path, 'p.diff')).writeAsStringSync(filteredPatch('f', s.parsed, s.excluded));
          final r = Process.runSync('git', ['-c', 'core.autocrlf=false', 'apply', '--unidiff-zero', 'p.diff'],
              workingDirectory: dir.path);
          expect(r.exitCode, 0, reason: '${r.stderr}');
          expect(File(p.join(dir.path, 'f')).readAsStringSync(), s.content, reason: 'round $round');
        } finally {
          dir.deleteSync(recursive: true);
        }
      }
    });

    test('selection survives an edit elsewhere', () {
      final newText = old.replaceFirst('b\n', 'B\n').replaceFirst('k\n', 'K\n');
      final s = applySel(old, newText, (l) => l.text != 'K');
      final parsed2 = parseDiff(gitDiff(old, 'inserted at top\n$newText'));
      final excluded2 = remapSelection(parsed2, describeSelection(s.parsed, s.excluded));
      expect(excluded2.length, 1);
      expect(buildContent(old, parsed2, excluded2),
          'inserted at top\n${old.replaceFirst('b\n', 'B\n').replaceFirst('k\n', '')}');
      expect(parsed2.signature, isNot(s.parsed.signature));
    });
  });

  group('commitSelected', () {
    late Directory dir;
    late GitRepository repo;
    String git(List<String> args) {
      final r = Process.runSync('git', args, workingDirectory: dir.path);
      if (r.exitCode != 0) fail('git ${args.join(' ')}: ${r.stderr}');
      return r.stdout as String;
    }

    void write(String name, String content) => File(p.join(dir.path, name)).writeAsStringSync(content);

    setUp(() {
      dir = Directory.systemTemp.createTempSync('gt_partial_');
      git(['init', '-q', '-b', 'main']);
      git(['config', 'user.name', 'T']);
      git(['config', 'user.email', 't@t']);
      git(['config', 'core.autocrlf', 'false']);
      repo = GitRepository(dir.path);
    });

    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('only selected lines are committed, real index untouched', () async {
      write('f.txt', 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n');
      write('other.txt', 'o\n');
      await repo.commit(message: 'init', paths: ['f.txt', 'other.txt']);
      write('f.txt', 'ONE\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\n');
      write('other.txt', 'o2\n');
      git(['add', 'other.txt']);
      write('new.txt', 'new\n');

      final parsed = parseDiff(await repo.fileDiff('f.txt'));
      final excluded = <String>{};
      for (var i = 0; i < parsed.hunks.length; i++) {
        for (var j = 0; j < parsed.hunks[i].lines.length; j++) {
          if (parsed.hunks[i].lines[j].text == 'eleven') excluded.add(lineKey(i, j));
        }
      }
      final head = git(['show', 'HEAD:f.txt']);
      await repo.commitSelected(
        message: 'partial',
        fullPaths: ['new.txt'],
        partial: {'f.txt': buildContent(head, parsed, excluded)},
      );

      expect(git(['show', 'HEAD:f.txt']), 'ONE\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n');
      expect(git(['show', 'HEAD:new.txt']), 'new\n');
      expect(File(p.join(dir.path, 'f.txt')).readAsStringSync(), contains('eleven'));
      expect(git(['diff', '--cached', '--name-only']).trim(), 'other.txt');
      expect(git(['diff', '--', 'f.txt']), contains('+eleven'));
      expect(Directory(p.join(dir.path, '.git')).listSync().any((e) => p.basename(e.path).startsWith('gittools-index')), isFalse);
    });

    test('works with core.autocrlf=true and CRLF files', () async {
      git(['config', 'core.autocrlf', 'true']);
      write('w.txt', 'a\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng\r\nh\r\n');
      await repo.commit(message: 'init', paths: ['w.txt']);
      write('w.txt', 'A\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng\r\nH\r\n');
      final parsed = parseDiff(await repo.fileDiff('w.txt'));
      final excluded = <String>{};
      for (var i = 0; i < parsed.hunks.length; i++) {
        for (var j = 0; j < parsed.hunks[i].lines.length; j++) {
          if (RegExp(r'^[hH]\r?$').hasMatch(parsed.hunks[i].lines[j].text)) excluded.add(lineKey(i, j));
        }
      }
      final head = git(['show', 'HEAD:w.txt']);
      await repo.commitSelected(message: 'crlf', fullPaths: const [], partial: {'w.txt': buildContent(head, parsed, excluded)});
      expect(git(['show', 'HEAD:w.txt']), 'A\nb\nc\nd\ne\nf\ng\nh\n');
      final diff = git(['diff', '--', 'w.txt']);
      expect(diff, contains('-h'));
      expect(diff, contains('+H'));
    });
  });
}
