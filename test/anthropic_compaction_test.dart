import 'dart:convert';
import 'dart:io';

import 'package:crux_agent_sdk/crux_agent_sdk.dart';
import 'package:crux_agent_sdk/src/services/subagent/subagent_prompts.dart';
import 'package:crux_agent_sdk/src/utils/token_estimate.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

/// Returns a fixture file body: round 1 reads the oversized payload
/// the compaction gate must flatten, round 2 reads a short one that
/// must survive compaction untouched.
class FixtureFileTool extends ToolDef {
  final Map<String, String> files;
  final List<String> reads;
  FixtureFileTool(this.files, this.reads);

  @override
  final String name = 'read_file';

  @override
  String get description => 'read_file returns a fixture file body';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'path': {'type': 'string'},
    },
    'required': ['path'],
  };

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input,
    ToolContext context,
  ) async {
    final path = input['path'] as String;
    reads.add(path);
    return ToolResult(files[path] ?? '(missing)');
  }
}

/// Anthropic-wire SSE fixture: two tool_use rounds, then a plain
/// end_turn answer. Mirrors test/support/fixture_server.dart's
/// guarantees — deterministic, prefix-stable history, byte-stable
/// tool definitions — but emits Anthropic content-block events, so
/// the run goes through `formatToolResultForApi`'s user-message
/// tool_result shape end to end.
class AnthropicFixture {
  final HttpServer server;
  final List<Map<String, dynamic>> requests = [];
  String? error;
  AnthropicFixture._(this.server);

  static Future<AnthropicFixture> start() async {
    final fixture = AnthropicFixture._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    fixture.server.listen((request) => fixture._serve(request));
    return fixture;
  }

  String get endpoint => 'http://127.0.0.1:${server.port}';
  Future<void> close() => server.close(force: true);

  /// Every `tool_result` block inside the request's user messages —
  /// the Anthropic-compatible tool-result shape (as opposed to the
  /// OpenAI standalone `{role: 'tool'}` message).
  List<Map<String, dynamic>> toolResultBlocks(Map<String, dynamic> body) => [
    for (final message in body['messages'] as List)
      if (message is Map && message['role'] == 'user')
        for (final block in _blocksOf(message))
          if (block is Map && block['type'] == 'tool_result')
            block as Map<String, dynamic>,
  ];

  /// Length of the oversized payload this fixture serves for
  /// `big.txt`, and the placeholder the compaction gate must write.
  static const bigOutputChars = 20000;
  static String get compactedPlaceholder =>
      '[compacted — $bigOutputChars chars, read again if needed]';
  static const _compactedSentinel = '<compacted>';

  Set<String> toolUseIds(Map<String, dynamic> body) => {
    for (final message in body['messages'] as List)
      if (message is Map && message['role'] == 'assistant')
        for (final block in _blocksOf(message))
          if (block is Map && block['type'] == 'tool_use')
            block['id'] as String,
  };

  /// Content blocks of a wire message; empty for string-content
  /// messages (plain user text, for instance).
  static List _blocksOf(Map message) {
    final content = message['content'];
    return content is List ? content : const [];
  }

  List<dynamic> _canonicalMessages(List messages) => [
    for (final message in messages)
      if (message is Map)
        {
          'role': message['role'],
          'content': _canonicalContent(message['content']),
        },
  ];

  dynamic _canonicalContent(dynamic content) {
    if (content is String) {
      return content == compactedPlaceholder
          ? _compactedSentinel
          : [
              {'type': 'text', 'text': content},
            ];
    }
    if (content is List) {
      return [for (final block in content) _canonicalBlock(block)];
    }
    return content;
  }

  dynamic _canonicalBlock(dynamic block) {
    if (block is! Map) return block;
    return {
      for (final entry in block.entries)
        if (entry.key != 'cache_control')
          entry.key:
              entry.key == 'content' && entry.value == compactedPlaceholder
              ? _compactedSentinel
              : entry.value,
    };
  }

  void _sse(StringSink out, String event, Map<String, dynamic> data) {
    out.write('event: $event\ndata: ${jsonEncode(data)}\n\n');
  }

  Future<void> _serve(HttpRequest request) async {
    try {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      requests.add(body);
      if (requests.length > 1) {
        final previous = requests[requests.length - 2];
        if (jsonEncode(body['tools']) != jsonEncode(previous['tools']))
          throw StateError('Tool definitions changed');
        final prior = previous['messages'] as List;
        // The prefix must stay stable modulo three legitimate rewrites:
        // (a) the provider strips `system` out of `messages` and moves
        //     the `cache_control` marker onto the last message each
        //     round; (b) it rewrites the last message's string content
        //     into a text block; (c) the compaction gate replaces
        //     oversized tool_result payloads with the placeholder —
        //     that rewrite is exactly the behavior under test. Any
        //     OTHER history change still trips this guard.
        if (jsonEncode(
              _canonicalMessages(
                (body['messages'] as List).take(prior.length).toList(),
              ),
            ) !=
            jsonEncode(_canonicalMessages(prior)))
          throw StateError('History prefix changed');
      }
      // Pairing sanity: compaction must never sever a tool_result
      // from its assistant tool_use — that is a 400 upstream.
      final useIds = toolUseIds(body);
      for (final result in toolResultBlocks(body)) {
        if (!useIds.contains(result['tool_use_id']))
          throw StateError(
            'tool_result ${result['tool_use_id']} lost its tool_use pair',
          );
      }

      final round = requests.length;
      final out = StringBuffer();
      _sse(out, 'message_start', {
        'type': 'message_start',
        'message': {
          'usage': {'input_tokens': 10},
        },
      });
      if (round <= 2) {
        final id = 'crux-ant-$round';
        final args = jsonEncode({'path': round == 1 ? 'big.txt' : 'small.txt'});
        final cut = args.length ~/ 2;
        _sse(out, 'content_block_start', {
          'type': 'content_block_start',
          'index': 0,
          'content_block': {'type': 'tool_use', 'id': id, 'name': 'read_file'},
        });
        _sse(out, 'content_block_delta', {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {
            'type': 'input_json_delta',
            'partial_json': args.substring(0, cut),
          },
        });
        _sse(out, 'content_block_delta', {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {
            'type': 'input_json_delta',
            'partial_json': args.substring(cut),
          },
        });
        _sse(out, 'message_delta', {
          'type': 'message_delta',
          'delta': {'stop_reason': 'tool_use'},
          'usage': {'output_tokens': 20},
        });
      } else {
        _sse(out, 'content_block_delta', {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'text_delta', 'text': 'Anthropic compaction ok.'},
        });
        _sse(out, 'message_delta', {
          'type': 'message_delta',
          'delta': {'stop_reason': 'end_turn'},
          'usage': {'output_tokens': 12},
        });
      }
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      request.response.bufferOutput = false;
      // Split the SSE stream at arbitrary byte boundaries to exercise
      // the transport decoder, not just whole-frame parsing.
      final bytes = utf8.encode(out.toString());
      for (var i = 0; i < bytes.length; i += 7) {
        request.response.add(bytes.sublist(i, (i + 7).clamp(0, bytes.length)));
        await request.response.flush();
      }
      await request.response.close();
    } catch (e) {
      error = '$e';
      try {
        await request.response.close();
      } catch (_) {}
    }
  }
}

Future<void> main() async {
  final files = <String, String>{
    'big.txt': 'X' * AnthropicFixture.bigOutputChars,
    'small.txt': 'tiny file body',
  };
  final reads = <String>[];
  final tools = [FixtureFileTool(files, reads)];

  const agentName = 'fixer';
  const intention = 'read two fixture files';
  const assignment = 'read big.txt then small.txt';
  final fixture = await AnthropicFixture.start();
  String? status;
  String? report;
  try {
    final config = ProviderConfig(
      name: 'fixture-anthropic',
      type: 'anthropic_compatible',
      wireFamily: WireFamily.anthropicCompatible,
      endpointUrl: fixture.endpoint,
      models: const [],
    );
    // Self-tuned three-stage gate: the opening history is the same
    // two messages the runner builds (system prompt + assignment), so
    // estimate its size here and set the capacity so the gate's
    // threshold lands base + 2500 tokens. The opening history stays
    // under it, the 20000-char tool result (~5000 tokens) pushes past
    // it at round 2, and the compacted history drops back under — the
    // gate fires exactly once and never reaches the distill stage.
    final baseTokens =
        estimateTokens(
          subagentSystemPrompt(
            agentName: agentName,
            role: SubagentRole.worker,
            domain: '',
            knowledge: '',
            worklog: '',
            intention: intention,
            userLanguage: 'English',
          ),
        ) +
        estimateTokens(assignment);
    final contextCapacity = ((baseTokens + 2500) * 4) ~/ 3 + 1;

    final runner = AgentRunner(
      agentName: agentName,
      profile: const AgentProfile(model: 'fixture-anthropic/claude-fixture'),
      role: SubagentRole.worker,
      intention: intention,
      message: assignment,
      providerService: StaticProviderRegistry.single(config, 'fixture-only'),
      tools: tools,
      toolExecutor: ToolExecutor(tools),
      sessionId: 1,
      workingDirectory: '.',
      reasoningEffort: 'off',
      contextCapacity: contextCapacity,
      onDone: (s, r) {
        status = s;
        report = r;
      },
    );
    await runner.start().timeout(const Duration(seconds: 10));

    check(
      status == 'completed' && report == 'Anthropic compaction ok.',
      'run did not complete cleanly: status=$status report=$report '
      'reads=$reads requests=${fixture.requests.length} '
      'fixtureError=${fixture.error}',
    );
    check(reads.join(',') == 'big.txt,small.txt', 'wrong read sequence');
    check(
      fixture.requests.length == 3 && fixture.error == null,
      'expected 3 clean requests, got ${fixture.requests.length}, '
      'fixture error: ${fixture.error}',
    );
    check(
      fixture.toolResultBlocks(fixture.requests[0]).isEmpty,
      'opening request already carried tool results',
    );

    // THE FIX: the round-2 request (built right after the gate
    // compacted) must carry the placeholder instead of the 20000-char
    // payload. Before the fix the Anthropic-shaped tool_result block
    // was never rewritten and the full payload rode along forever.
    final placeholder = AnthropicFixture.compactedPlaceholder;
    final round2Results = fixture.toolResultBlocks(fixture.requests[1]);
    check(
      round2Results.length == 1,
      'round 2 has ${round2Results.length} results',
    );
    check(
      round2Results[0]['tool_use_id'] == 'crux-ant-1',
      'compaction lost the tool_use_id pairing',
    );
    check(
      round2Results[0]['content'] == placeholder,
      'oversized Anthropic tool_result was not compacted: '
      'got ${'${round2Results[0]['content']}'.length} chars',
    );

    // Round 3: compaction persists, and the short result is untouched
    // (no over-compaction).
    final round3Results = fixture.toolResultBlocks(fixture.requests[2]);
    check(
      round3Results.length == 2,
      'round 3 has ${round3Results.length} results',
    );
    check(
      round3Results[0]['content'] == placeholder &&
          round3Results[0]['tool_use_id'] == 'crux-ant-1',
      'round 3 lost the compacted big result',
    );
    check(
      round3Results[1]['content'] == 'tiny file body' &&
          round3Results[1]['tool_use_id'] == 'crux-ant-2',
      'short tool_result was over-compacted or unpaired',
    );
    print('PASS anthropic tool-result compaction');
  } finally {
    await fixture.close();
  }
}
