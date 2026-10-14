import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:git_tools/ai/commit_message_ai.dart';
import 'package:git_tools/git/git_repository.dart';
import 'package:git_tools/git/models.dart';
import 'package:path/path.dart' as p;

/// Local HTTP server that replays a canned response and records requests.
class FakeApi {
  late HttpServer server;
  final requests = <(HttpHeaders, Map<String, dynamic>)>[];
  int status = 200;
  List<String> events = [];
  String errorBody = '';

  Uri get url => Uri.parse('http://127.0.0.1:${server.port}/v1');

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
      requests.add((req.headers, body));
      req.response.statusCode = status;
      if (status != 200) {
        req.response.write(errorBody);
      } else {
        req.response.headers.contentType = ContentType('text', 'event-stream');
        for (final e in events) {
          req.response.write('data: $e\n\n');
        }
      }
      await req.response.close();
    });
  }
}

String claudeDelta(String t) => jsonEncode({
      'type': 'content_block_delta',
      'index': 0,
      'delta': {'type': 'text_delta', 'text': t},
    });

String geminiDelta(String t) => jsonEncode({
      'choices': [
        {'index': 0, 'delta': {'content': t}},
      ],
    });

const req = CommitMessageRequest(
  files: ['Modified: lib/main.dart'],
  diff: '--- a\n+++ b\n-a\n+b\n',
  branch: 'main',
  recentSubjects: ['Add login screen'],
  language: 'English',
);

void main() {
  late FakeApi api;
  setUp(() async {
    api = FakeApi();
    await api.start();
  });
  tearDown(() => api.server.close(force: true));

  group('Claude', () {
    test('streams text and sends the expected request', () async {
      api.events = [
        jsonEncode({'type': 'message_start', 'message': {}}),
        jsonEncode({'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}}),
        claudeDelta('Fix greeting'),
        claudeDelta(' text\n\nUse the new wording.'),
        jsonEncode({'type': 'message_delta', 'delta': {'stop_reason': 'end_turn'}}),
        jsonEncode({'type': 'message_stop'}),
      ];
      final ai = ClaudeCommitAi(apiKey: 'k1', model: 'claude-opus-5-5', endpoint: api.url);
      final seen = <String>[];
      final msg = await ai.generate(req, onText: seen.add);
      expect(msg, 'Fix greeting text\n\nUse the new wording.');
      expect(seen.first, 'Fix greeting');

      final (headers, body) = api.requests.single;
      expect(headers.value('x-api-key'), 'k1');
      expect(headers.value('anthropic-version'), '2023-06-01');
      expect(headers.value('anthropic-beta'), 'server-side-fallback-2026-07-01');
      expect(body['model'], 'claude-opus-5-5');
      expect(body['stream'], true);
      expect(body['fallbacks'], 'default');
      expect(body['output_config'], {'effort': 'low'});
      final content = (body['messages'] as List).single['content'] as String;
      expect(content, contains('Write the commit message in English.'));
      expect(content, contains('- Add login screen'));
      expect(content, contains('<diff>'));
    });

    test('older models get no fallbacks or effort fields', () async {
      api.events = [claudeDelta('Update docs')];
      final ai = ClaudeCommitAi(apiKey: 'k', model: 'claude-haiku-4-5', endpoint: api.url);
      await ai.generate(req, onText: (_) {});
      final (headers, body) = api.requests.single;
      expect(headers.value('anthropic-beta'), isNull);
      expect(body.containsKey('fallbacks'), isFalse);
      expect(body.containsKey('output_config'), isFalse);
    });

    test('fallback block discards partial output', () async {
      api.events = [
        claudeDelta('partial from first'),
        jsonEncode({'type': 'content_block_start', 'index': 1, 'content_block': {'type': 'fallback'}}),
        claudeDelta('Final message'),
      ];
      final ai = ClaudeCommitAi(apiKey: 'k', model: 'claude-opus-5-5', endpoint: api.url);
      expect(await ai.generate(req, onText: (_) {}), 'Final message');
    });

    test('refusal and HTTP errors become AiException', () async {
      api.events = [jsonEncode({'type': 'message_delta', 'delta': {'stop_reason': 'refusal'}})];
      final ai = ClaudeCommitAi(apiKey: 'k', model: 'claude-opus-5-5', endpoint: api.url);
      await expectLater(ai.generate(req, onText: (_) {}),
          throwsA(isA<AiException>().having((e) => e.message, 'message', contains('declined'))));

      api.status = 401;
      api.errorBody = jsonEncode({'type': 'error', 'error': {'type': 'authentication_error', 'message': 'invalid x-api-key'}});
      await expectLater(ai.generate(req, onText: (_) {}),
          throwsA(isA<AiException>().having((e) => e.message, 'message', allOf(contains('Invalid Claude API key'), contains('invalid x-api-key')))));
    });

    test('strips code fences', () async {
      api.events = [claudeDelta('```\nAdd feature\n```')];
      final ai = ClaudeCommitAi(apiKey: 'k', model: 'claude-opus-5-5', endpoint: api.url);
      expect(await ai.generate(req, onText: (_) {}), 'Add feature');
    });
  });

  group('Gemini', () {
    test('streams OpenAI-compatible chunks', () async {
      api.events = [geminiDelta('feat: add'), geminiDelta(' login'), '[DONE]'];
      final ai = GeminiCommitAi(apiKey: 'g1', model: 'gemini-3.8-flash', endpoint: api.url);
      expect(await ai.generate(req, onText: (_) {}), 'feat: add login');
      final (headers, body) = api.requests.single;
      expect(headers.value('authorization'), 'Bearer g1');
      expect(body['model'], 'gemini-3.8-flash');
      expect(body['reasoning_effort'], 'low');
      final messages = body['messages'] as List;
      expect(messages.first['role'], 'system');
      expect(messages.last['content'], contains('Modified: lib/main.dart'));
    });

    test('quota errors (list-shaped body) are explained', () async {
      api.status = 429;
      api.errorBody = jsonEncode([
        {'error': {'code': 429, 'message': 'Resource has been exhausted', 'status': 'RESOURCE_EXHAUSTED'}},
      ]);
      final ai = GeminiCommitAi(apiKey: 'g', model: 'gemini-3.8-flash', endpoint: api.url);
      await expectLater(ai.generate(req, onText: (_) {}),
          throwsA(isA<AiException>().having((e) => e.message, 'message', allOf(contains('quota'), contains('exhausted')))));
    });

    test('test connection succeeds on any reply', () async {
      api.events = [geminiDelta('OK'), '[DONE]'];
      final ai = GeminiCommitAi(apiKey: 'g', model: 'gemini-3.5-flash-lite', endpoint: api.url);
      await ai.testConnection();
    });
  });

  test('diffPerFile returns tracked diffs and new file contents', () async {
    final dir = await Directory.systemTemp.createTemp('git_tools_ai');
    Future<void> git(List<String> a) async {
      final r = await Process.run('git', a, workingDirectory: dir.path);
      if (r.exitCode != 0) fail('${r.stderr}');
    }

    await git(['init', '-q', '-b', 'main']);
    await git(['config', 'user.name', 'T']);
    await git(['config', 'user.email', 't@t']);
    await git(['config', 'core.autocrlf', 'false']);
    File(p.join(dir.path, 'a.txt')).writeAsStringSync('one\n');
    await git(['add', '-A']);
    await git(['commit', '-qm', 'init']);
    File(p.join(dir.path, 'a.txt')).writeAsStringSync('two\n');
    File(p.join(dir.path, 'new.txt')).writeAsStringSync('hello\n');

    final repo = GitRepository(dir.path);
    final diffs = await repo.diffPerFile([
      const FileChange(path: 'a.txt', type: ChangeType.modified),
      const FileChange(path: 'new.txt', type: ChangeType.untracked),
    ], base: 'HEAD');
    expect(diffs.keys.toSet(), {'a.txt', 'new.txt'});
    expect(diffs['a.txt'], allOf(contains('-one'), contains('+two')));
    expect(diffs['new.txt'], contains('+hello'));
    expect(await repo.recentSubjects(), ['init']);
    await dir.delete(recursive: true);
  });
}
