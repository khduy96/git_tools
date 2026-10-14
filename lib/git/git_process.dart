import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One line in the Git console (like the "Console" tab of Android Studio).
class ConsoleEntry {
  ConsoleEntry(this.text, this.kind) : time = DateTime.now();

  final String text;
  final ConsoleKind kind;
  final DateTime time;
}

enum ConsoleKind { command, output, error, info }

class GitException implements Exception {
  GitException(this.args, this.exitCode, this.stderr, this.stdout);

  final List<String> args;
  final int exitCode;
  final String stderr;
  final String stdout;

  String get message {
    final err = stderr.trim();
    if (err.isNotEmpty) return err;
    final out = stdout.trim();
    if (out.isNotEmpty) return out;
    return 'git ${args.join(' ')} failed with exit code $exitCode';
  }

  @override
  String toString() => message;
}

class GitResult {
  GitResult(this.exitCode, this.stdoutBytes, this.stderr);

  final int exitCode;
  final List<int> stdoutBytes;
  final String stderr;

  String get stdout => utf8.decode(stdoutBytes, allowMalformed: true);
}

/// Thin wrapper around the git executable.
class GitProcess {
  GitProcess(this.workingDirectory, {this.onConsole});

  final String workingDirectory;
  final void Function(ConsoleEntry entry)? onConsole;

  static const _utf8 = Utf8Codec(allowMalformed: true);

  static final Map<String, String> _env = {
    'GIT_TERMINAL_PROMPT': '0',
    'LANG': 'en_US.UTF-8',
    'LC_ALL': 'C.UTF-8',
    // Never open an interactive editor from this tool.
    'GIT_EDITOR': 'true',
    'GIT_SEQUENCE_EDITOR': 'true',
    'GIT_MERGE_AUTOEDIT': 'no',
  };

  static const List<String> _globalArgs = [
    '-c', 'core.quotepath=false',
    '-c', 'color.ui=false',
    '-c', 'i18n.logOutputEncoding=UTF-8',
    '-c', 'advice.detachedHead=false',
  ];

  /// Runs git and returns stdout. Throws [GitException] on non-zero exit
  /// unless [allowFailure] is set.
  Future<String> run(
    List<String> args, {
    bool log = false,
    bool allowFailure = false,
    String? stdin,
  }) async {
    final r = await runRaw(args, log: log, stdin: stdin);
    if (r.exitCode != 0 && !allowFailure) {
      throw GitException(args, r.exitCode, r.stderr, r.stdout);
    }
    return r.stdout;
  }

  Future<GitResult> runRaw(
    List<String> args, {
    bool log = false,
    String? stdin,
  }) async {
    if (log) _emit('git ${args.map(_quote).join(' ')}', ConsoleKind.command);
    final process = await Process.start(
      'git',
      [..._globalArgs, ...args],
      workingDirectory: workingDirectory,
      environment: _env,
      runInShell: false,
    );
    if (stdin != null) {
      process.stdin.add(utf8.encode(stdin));
    }
    await process.stdin.close();

    final outBytes = <int>[];
    final errBuf = StringBuffer();
    final outDone = process.stdout.listen(outBytes.addAll).asFuture<void>();
    final errDone = process.stderr
        .transform(_utf8.decoder)
        .listen((chunk) {
          errBuf.write(chunk);
          if (log) {
            for (final line in const LineSplitter().convert(chunk)) {
              if (line.trim().isNotEmpty) _emit(line, ConsoleKind.output);
            }
          }
        })
        .asFuture<void>();
    final code = await process.exitCode;
    await Future.wait([outDone, errDone]);
    final result = GitResult(code, outBytes, errBuf.toString());
    if (log) {
      final out = result.stdout.trim();
      if (out.isNotEmpty) {
        final lines = const LineSplitter().convert(out);
        for (final line in lines.take(200)) {
          _emit(line, ConsoleKind.output);
        }
        if (lines.length > 200) {
          _emit('… ${lines.length - 200} more lines', ConsoleKind.output);
        }
      }
      if (code != 0) _emit('exit code $code', ConsoleKind.error);
    }
    return result;
  }

  void info(String text) => _emit(text, ConsoleKind.info);

  void _emit(String text, ConsoleKind kind) =>
      onConsole?.call(ConsoleEntry(text, kind));

  static String _quote(String a) =>
      a.isEmpty || a.contains(' ') ? '"$a"' : a;
}
