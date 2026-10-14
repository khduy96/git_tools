import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Raised when an AI call fails, is declined or is cancelled.
class AiException implements Exception {
  AiException(this.message, {this.cancelled = false});

  final String message;
  final bool cancelled;

  @override
  String toString() => message;
}

/// Input for one commit message generation.
class CommitMessageRequest {
  const CommitMessageRequest({
    required this.files,
    required this.diff,
    this.branch = '',
    this.recentSubjects = const [],
    this.language = '',
    this.instructions = '',
    this.amendOf,
  });

  /// Current branch name (empty when detached).
  final String branch;

  /// `<status> <path>` lines of the changes being committed.
  final List<String> files;
  final String diff;
  final List<String> recentSubjects;

  /// Language for the message; empty lets the model follow the history.
  final String language;
  final String instructions;

  /// Message of the commit being amended, if any.
  final String? amendOf;

  String toPrompt() {
    final b = StringBuffer();
    if (language.trim().isNotEmpty) {
      b
        ..writeln('Write the commit message in ${language.trim()}.')
        ..writeln();
    }
    if (instructions.trim().isNotEmpty) {
      b
        ..writeln('Additional instructions from the developer:')
        ..writeln(instructions.trim())
        ..writeln();
    }
    if (branch.isNotEmpty) b.writeln('Branch: $branch');
    if (recentSubjects.isNotEmpty) {
      b
        ..writeln()
        ..writeln('Recent commit subjects in this repository (newest first):')
        ..writeln(recentSubjects.map((s) => '- $s').join('\n'));
    }
    if (amendOf != null) {
      b
        ..writeln()
        ..writeln('This amends the previous commit, whose current message is:')
        ..writeln(amendOf);
    }
    b
      ..writeln()
      ..writeln('Files in this commit:')
      ..writeln(files.join('\n'))
      ..writeln()
      ..writeln('<diff>')
      ..writeln(diff)
      ..writeln('</diff>');
    return b.toString();
  }
}

const systemPrompt = '''
You write git commit messages for the changes a developer is about to commit.

Write the message the way an experienced engineer on this project would:
- First line: a concise summary of what the change does, in the imperative mood ("Add", "Fix", "Refactor"), at most 72 characters, no trailing period.
- If the change is more than trivial, add a blank line and then a short body explaining what changed and why, wrapped at about 72 characters. Bullet points are fine for several independent changes. Skip the body for small, self-explanatory changes.
- Follow the conventions visible in the project's recent commit subjects (for example a "feat:"/"fix:" prefix, ticket ids, capitalization, language) when they are consistent.
- Describe the intent of the change, not a file-by-file narration. Do not invent motivations that the diff does not support.

Reply with the commit message only: no preamble, no quotes, no Markdown code fences.''';

/// Common streaming client for the supported providers.
abstract class CommitMessageAi {
  CommitMessageAi({required this.apiKey, required this.model, this.endpoint});

  final String apiKey;
  final String model;

  /// Overrides the API URL (used by tests).
  final Uri? endpoint;
  HttpClient? _client;
  bool _cancelled = false;

  /// Streams the message; [onText] receives the full text generated so far.
  Future<String> generate(
    CommitMessageRequest req, {
    required void Function(String text) onText,
  }) async {
    final text = await _stream(systemPrompt, req.toPrompt(), onText: (t) => onText(_clean(t)));
    final result = _clean(text);
    if (result.isEmpty) throw AiException('The model returned an empty message.');
    return result;
  }

  /// Sends a tiny request to check the key and model.
  Future<void> testConnection() async {
    final text = await _stream(
      'You are a connectivity check.',
      'Reply with the single word OK.',
      onText: (_) {},
    );
    if (text.trim().isEmpty) throw AiException('The model returned an empty reply.');
  }

  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  Future<String> _stream(String system, String user,
      {required void Function(String) onText});

  /// Opens a streaming POST and yields the SSE `data:` payloads.
  Stream<String> _sse(Uri url, Map<String, String> headers, Object body) async* {
    _cancelled = false;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    _client = client;
    try {
      final request = await client.postUrl(url);
      headers.forEach(request.headers.set);
      request.headers.set('content-type', 'application/json');
      request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close();
      if (response.statusCode != 200) {
        final text = await response.transform(utf8.decoder).join();
        throw AiException(_httpError(response.statusCode, text));
      }
      await for (final line in response
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data.isNotEmpty) yield data;
      }
    } on AiException {
      rethrow;
    } on Object catch (e) {
      if (_cancelled) throw AiException('Cancelled', cancelled: true);
      if (e is SocketException) throw AiException('Network error: ${e.message}');
      if (e is HttpException) throw AiException('Network error: ${e.message}');
      if (e is FormatException) throw AiException('Unexpected response: ${e.message}');
      rethrow;
    } finally {
      _client = null;
      client.close();
    }
    if (_cancelled) throw AiException('Cancelled', cancelled: true);
  }

  String _httpError(int status, String body);

  /// Extracts `error.message` from a JSON error body (object or list).
  static String? errorMessageFrom(String body) {
    try {
      var j = jsonDecode(body);
      if (j is List && j.isNotEmpty) j = j.first;
      if (j is Map) {
        final err = j['error'];
        if (err is Map && err['message'] is String) return err['message'] as String;
      }
    } catch (_) {}
    return null;
  }

  /// Strips accidental code fences and surrounding whitespace.
  static String _clean(String text) {
    var t = text.trim();
    if (t.startsWith('```')) {
      t = t.replaceFirst(RegExp(r'^```[a-zA-Z]*\n?'), '');
      t = t.replaceFirst(RegExp(r'\n?```$'), '');
    }
    return t.trim();
  }
}

/// Anthropic Claude via the Messages API.
class ClaudeCommitAi extends CommitMessageAi {
  ClaudeCommitAi({required super.apiKey, required super.model, super.endpoint});

  static final _url = Uri.parse('https://api.anthropic.com/v1/messages');

  /// Models that accept the server-side `fallbacks: "default"` option.
  static const _fallbackModels = {
    'claude-opus-5-5',
    'claude-opus-5',
    'claude-fable-5-1',
    'claude-sonnet-5-5',
  };

  /// Models that accept `output_config.effort`.
  bool get _supportsEffort =>
      RegExp(r'^claude-(opus-(5|4-[5-8])|fable-5|sonnet-(5|4-6)|haiku-5)').hasMatch(model);

  @override
  Future<String> _stream(String system, String user,
      {required void Function(String) onText}) async {
    final fallback = _fallbackModels.contains(model);
    var text = '';
    String? stopReason;
    await for (final data in _sse(
      endpoint ?? _url,
      {
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
        if (fallback) 'anthropic-beta': 'server-side-fallback-2026-07-01',
      },
      {
        'model': model,
        'max_tokens': 16000,
        'stream': true,
        // Commit messages are a light task.
        if (_supportsEffort) 'output_config': {'effort': 'low'},
        // Re-run a safety-classifier decline on Anthropic's recommended model.
        if (fallback) 'fallbacks': 'default',
        'system': system,
        'messages': [
          {'role': 'user', 'content': user},
        ],
      },
    )) {
      final event = jsonDecode(data) as Map<String, dynamic>;
      switch (event['type']) {
        case 'content_block_start':
          // A fallback boundary: the declined model's partial output is
          // superseded by the fallback model's answer.
          final block = event['content_block'] as Map<String, dynamic>?;
          if (block?['type'] == 'fallback') {
            text = '';
            onText(text);
          }
        case 'content_block_delta':
          final delta = event['delta'] as Map<String, dynamic>;
          if (delta['type'] == 'text_delta') {
            text += delta['text'] as String;
            onText(text);
          }
        case 'message_delta':
          final delta = event['delta'] as Map<String, dynamic>?;
          stopReason = delta?['stop_reason'] as String? ?? stopReason;
        case 'error':
          final err = event['error'] as Map<String, dynamic>?;
          throw AiException(err?['message'] as String? ?? 'Streaming error');
      }
    }
    if (stopReason == 'refusal') {
      throw AiException('Claude declined this request.');
    }
    return text;
  }

  @override
  String _httpError(int status, String body) {
    final msg = CommitMessageAi.errorMessageFrom(body);
    final hint = switch (status) {
      401 => 'Invalid Claude API key.',
      403 => 'This API key is not allowed to use this model.',
      404 => 'Unknown Claude model "$model".',
      429 => 'Claude rate limit reached. Try again in a moment.',
      529 => 'The Claude API is overloaded. Try again in a moment.',
      _ => 'Claude API error (HTTP $status).',
    };
    return msg == null ? hint : '$hint\n$msg';
  }
}

/// Google Gemini via its OpenAI-compatible endpoint.
class GeminiCommitAi extends CommitMessageAi {
  GeminiCommitAi({required super.apiKey, required super.model, super.endpoint});

  static final _url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions');

  @override
  Future<String> _stream(String system, String user,
      {required void Function(String) onText}) async {
    var text = '';
    String? finish;
    await for (final data in _sse(
      endpoint ?? _url,
      {'authorization': 'Bearer $apiKey'},
      {
        'model': model,
        'stream': true,
        // Little reasoning is needed; saves free-tier tokens and time.
        'reasoning_effort': 'low',
        'messages': [
          {'role': 'system', 'content': system},
          {'role': 'user', 'content': user},
        ],
      },
    )) {
      if (data == '[DONE]') break;
      final event = jsonDecode(data);
      if (event is Map && event['error'] != null) {
        throw AiException(CommitMessageAi.errorMessageFrom(data) ?? 'Gemini streaming error');
      }
      final choices = (event as Map)['choices'] as List? ?? const [];
      for (final c in choices) {
        final delta = (c as Map)['delta'] as Map?;
        final content = delta?['content'];
        if (content is String && content.isNotEmpty) {
          text += content;
          onText(text);
        }
        finish = c['finish_reason'] as String? ?? finish;
      }
    }
    if (finish == 'content_filter' || finish == 'safety') {
      throw AiException('Gemini blocked this request (safety filter).');
    }
    return text;
  }

  @override
  String _httpError(int status, String body) {
    final msg = CommitMessageAi.errorMessageFrom(body);
    final hint = switch (status) {
      400 => 'Gemini rejected the request (check the model name and API key).',
      401 || 403 => 'Invalid Gemini API key or the key has no access to this model.',
      404 => 'Unknown Gemini model "$model".',
      429 => 'Gemini quota exceeded (free tier limit reached). Try later or switch model.',
      503 => 'Gemini is overloaded. Try again in a moment.',
      _ => 'Gemini API error (HTTP $status).',
    };
    return msg == null ? hint : '$hint\n$msg';
  }
}
