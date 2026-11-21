import 'dart:convert';
import 'dart:io';

import 'package:crux_agent_sdk/crux_agent_sdk.dart';
import 'package:crux_agent_sdk/src/services/subagent/history_compactor.dart';
import 'package:crux_agent_sdk/src/services/subagent/subagent_prompts.dart';
import 'package:crux_agent_sdk/src/utils/token_estimate.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

/// The two automatic-compaction modes under test:
///  - compact: 1st/2nd context-full event, every tool OUTPUT is dropped and
///    every tool CALL collapses to its intent (or keeps its input
///    parameters when the call carries no intent) — zero extra LLM calls.
///  - distill: 3rd context-full event, one distillation call produces
///    knowledge/worklog/instruction, then the run resumes on a clean
///    CONTINUATION context.
const int bigOutputChars = 20000;

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

/// OpenAI-wire SSE fixture. Each conversation round is scripted by the
/// caller; a request whose system prompt is the distillation head is
/// answered with the three distillation markers.
class OpenAiFixture {
  final HttpServer server;
  final List<Map<String, dynamic>> requests = [];
  final String Function(int conversationRound) pathForRound;
  final int toolRounds;
  final String finalAnswer;
  String? error;
  int conversationRounds = 0;

  OpenAiFixture._(
    this.server,
    this.pathForRound,
    this.toolRounds,
    this.finalAnswer,
  );

  static Future<OpenAiFixture> start({
    required String Function(int round) pathForRound,
    required int toolRounds,
    required String finalAnswer,
  }) async {
    final fixture = OpenAiFixture._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      pathForRound,
      toolRounds,
      finalAnswer,
    );
    fixture.server.listen((request) => fixture._serve(request));
    return fixture;
  }

  String get endpoint => 'http://127.0.0.1:${server.port}';
  Future<void> close() => server.close(force: true);

  bool get sawDistillation => requests.any(_isDistillationRequest);

  static bool _isDistillationRequest(Map<String, dynamic> body) {
    final messages = body['messages'];
    if (messages is! List || messages.isEmpty) return false;
    final first = messages.first;
    if (first is! Map) return false;
    final content = first['content'];
    return content is String &&
        content.startsWith('You are the distillation pass');
  }

  List<Map<String, dynamic>> toolMessages(Map<String, dynamic> body) => [
    for (final message in body['messages'] as List)
      if (message is Map && message['role'] == 'tool')
        message as Map<String, dynamic>,
  ];

  List<Map<String, dynamic>> _toolCallChunks(String id, String args) {
    final cut = args.length ~/ 2;
    return [
      {
        'choices': [
          {
            'delta': {
              'tool_calls': [
                {
                  'index': 0,
                  'id': id,
                  'type': 'function',
                  'function': {
                    'name': 'read_file',
                    'arguments': args.substring(0, cut),
                  },
                },
              ],
            },
            'finish_reason': null,
          },
        ],
      },
      {
        'choices': [
          {
            'delta': {
              'tool_calls': [
                {
                  'index': 0,
                  'function': {'arguments': args.substring(cut)},
                },
              ],
            },
            'finish_reason': null,
          },
        ],
      },
      {
        'choices': [
          {'delta': {}, 'finish_reason': 'tool_calls'},
        ],
      },
    ];
  }

  List<Map<String, dynamic>> _textChunks(String text) => [
    {
      'choices': [
        {
          'delta': {'content': text},
          'finish_reason': null,
        },
      ],
    },
    {
      'choices': [
        {'delta': {}, 'finish_reason': 'stop'},
      ],
    },
  ];

  Future<void> _serve(HttpRequest request) async {
    try {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      requests.add(body);

      List<Map<String, dynamic>> chunks;
      if (_isDistillationRequest(body)) {
        chunks = _textChunks(
          '===KNOWLEDGE===\n'
          'Fixture knowledge: the big files are deterministic fixtures.\n'
          '===WORKLOG===\n'
          'Read three oversized fixture files and compacted twice.\n'
          '===INSTRUCTION===\n'
          'Reply with the fixture completion marker.\n',
        );
      } else {
        conversationRounds++;
        final round = conversationRounds;
        if (round > toolRounds) {
          chunks = _textChunks(finalAnswer);
        } else {
          final path = pathForRound(round);
          chunks = _toolCallChunks(
            'fixture-$round',
            jsonEncode({'path': path}),
          );
        }
      }

      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      request.response.bufferOutput = false;
      for (final chunk in chunks) {
        // Split UTF-8 frames at arbitrary byte boundaries so the real
        // transport decoder is exercised, not just frame parsing.
        final bytes = utf8.encode('data: ${jsonEncode(chunk)}\n\n');
        for (var i = 0; i < bytes.length; i += 7) {
          request.response.add(
            bytes.sublist(i, (i + 7).clamp(0, bytes.length)),
          );
          await request.response.flush();
        }
      }
      request.response.write('data: [DONE]\n\n');
      await request.response.close();
    } catch (e) {
      error = '$e';
      try {
        await request.response.close();
      } catch (_) {}
    }
  }
}

ProviderConfig _fixtureConfig(OpenAiFixture fixture) => ProviderConfig(
  name: 'fixture-openai',
  type: 'openai_compatible',
  wireFamily: WireFamily.openaiCompatible,
  endpointUrl: fixture.endpoint,
  models: const [],
);

int _capacityForGate({
  required String agentName,
  required String intention,
  required String assignment,
}) {
  // Same self-tuned gate as the Anthropic compaction test: land the
  // 75% threshold at opening history + ~2500 tokens. The opening
  // history stays below; one 20000-char tool result (~5000 tokens)
  // pushes past; a compacted result drops back under.
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
  return ((baseTokens + 2500) * 4) ~/ 3 + 1;
}

AgentRunner _runner({
  required OpenAiFixture fixture,
  required List<ToolDef> tools,
  required String agentName,
  required String intention,
  required String assignment,
  required int contextCapacity,
  required void Function(String status, String report) onDone,
  Future<void> Function(String name, DistillationProducts products)?
  onDistilled,
  void Function(List<Map<String, dynamic>> history)? onHistory,
}) {
  return AgentRunner(
    agentName: agentName,
    profile: const AgentProfile(
      model: 'fixture-openai/fixture-model',
      domain: 'fixtures',
    ),
    role: SubagentRole.worker,
    intention: intention,
    message: assignment,
    providerService: StaticProviderRegistry.single(
      _fixtureConfig(fixture),
      'fixture-only',
    ),
    tools: tools,
    toolExecutor: ToolExecutor(tools),
    sessionId: 1,
    workingDirectory: '.',
    reasoningEffort: 'off',
    contextCapacity: contextCapacity,
    onDone: onDone,
    onDistilled: onDistilled,
    onHistory: onHistory,
  );
}

/// Case 0 — the compaction rule itself, on a synthetic history: a call
/// with an intent keeps only that intent, a call without one keeps its
/// input parameters, and every tool output is dropped while the
/// pairing ids stay in place.
void testCompactionRules() {
  final history = <Map<String, dynamic>>[
    {
      'role': 'assistant',
      'content': null,
      'tool_calls': [
        {
          'id': 'call-with-intent',
          'type': 'function',
          'function': {
            'name': 'read_file',
            'arguments': jsonEncode({
              'path': 'big.txt',
              'intent': 'check the fixture body',
            }),
          },
        },
        {
          'id': 'call-without-intent',
          'type': 'function',
          'function': {
            'name': 'read_file',
            'arguments': jsonEncode({'path': 'small.txt'}),
          },
        },
      ],
    },
    {'role': 'tool', 'tool_call_id': 'call-with-intent', 'content': 'X' * bigOutputChars},
    {'role': 'tool', 'tool_call_id': 'call-without-intent', 'content': 'tiny file body'},
    {
      'role': 'assistant',
      'content': [
        {
          'type': 'tool_use',
          'id': 'toolu-1',
          'name': 'read_file',
          'input': {'path': 'big.txt', 'intent': 'anthropic intent'},
        },
      ],
    },
    {
      'role': 'user',
      'content': [
        {
          'type': 'tool_result',
          'tool_use_id': 'toolu-1',
          'content': 'A' * bigOutputChars,
        },
      ],
    },
  ];

  compactToolHistory(history);

  final calls = (history[0]['tool_calls'] as List).cast<Map>();
  final withIntent = jsonDecode(
    ((calls[0]['function'] as Map)['arguments']) as String,
  ) as Map;
  check(
    withIntent.length == 1 && withIntent['intent'] == 'check the fixture body',
    'a call with an intent must keep only the intent: $withIntent',
  );
  final withoutIntent = jsonDecode(
    ((calls[1]['function'] as Map)['arguments']) as String,
  ) as Map;
  check(
    withoutIntent['path'] == 'small.txt',
    'a call without an intent must keep its input parameters: $withoutIntent',
  );

  check(
    history[1]['content'] == '' && history[2]['content'] == '',
    'every tool output must be dropped, oversized or not: '
    '${history[1]['content']} / ${history[2]['content']}',
  );
  check(
    history[1]['tool_call_id'] == 'call-with-intent' &&
        history[2]['tool_call_id'] == 'call-without-intent',
    'tool result pairing ids must survive compaction',
  );

  final anthropicCall = (history[3]['content'] as List).first as Map;
  check(
    (anthropicCall['input'] as Map).length == 1 &&
        (anthropicCall['input'] as Map)['intent'] == 'anthropic intent',
    'an Anthropic tool_use input must collapse to its intent: '
    '${anthropicCall['input']}',
  );
  final anthropicResult = (history[4]['content'] as List).first as Map;
  check(
    anthropicResult['content'] == '' && anthropicResult['tool_use_id'] == 'toolu-1',
    'an Anthropic tool_result must keep its id and drop its output',
  );

  print('PASS compaction rule (intent-only calls, dropped outputs)');
}

/// Case 1 — compact mode: the 1st context-full event drops an
/// oversized OpenAI `role: tool` payload, keeps
/// the assistant call line, makes zero distillation calls, and lets a
/// short result through untouched.
Future<void> testCompactMode() async {
  const agentName = 'compactor';
  const intention = 'read a big file then a small one';
  const assignment = 'read big.txt then small.txt';

  final files = <String, String>{
    'big.txt': 'X' * bigOutputChars,
    'small.txt': 'tiny file body',
  };
  final reads = <String>[];
  final tools = <ToolDef>[FixtureFileTool(files, reads)];

  final fixture = await OpenAiFixture.start(
    pathForRound: (round) => round == 1 ? 'big.txt' : 'small.txt',
    toolRounds: 2,
    finalAnswer: 'Compact mode ok.',
  );
  String? status;
  String? report;
  var historyCalls = 0;
  try {
    final runner = _runner(
      fixture: fixture,
      tools: tools,
      agentName: agentName,
      intention: intention,
      assignment: assignment,
      contextCapacity: _capacityForGate(
        agentName: agentName,
        intention: intention,
        assignment: assignment,
      ),
      onDone: (s, r) {
        status = s;
        report = r;
      },
      onHistory: (_) => historyCalls++,
    );
    await runner.start().timeout(const Duration(seconds: 10));

    check(
      status == 'completed' && report == 'Compact mode ok.',
      'compact run did not complete: status=$status report=$report '
      'reads=$reads requests=${fixture.requests.length} error=${fixture.error}',
    );
    check(
      reads.join(',') == 'big.txt,small.txt',
      'wrong read sequence: $reads; requests=${fixture.requests.length}; '
      'status=$status report=$report error=${fixture.error}',
    );
    check(
      fixture.requests.length == 3,
      'expected 3 conversation requests (no distill call), got '
      '${fixture.requests.length}, fixture error: ${fixture.error}',
    );
    check(
      !fixture.sawDistillation,
      'compact mode must not issue a distillation request',
    );
    check(historyCalls > 0, 'the run never reported intermediate history');

    // Round 2 was built after the gate fired: the oversized payload is
    // dropped, and the assistant tool_calls line survived with its
    // input parameters (these fixture calls carry no intent).
    final round2 = fixture.toolMessages(fixture.requests[1]);
    check(round2.length == 1, 'round 2 carries ${round2.length} tool results');
    check(
      round2[0]['content'] == '',
      'round 2 tool result was not dropped: '
      '${'${round2[0]['content']}'.length} chars',
    );
    final assistant = (fixture.requests[1]['messages'] as List)
        .where((m) => m is Map && m['role'] == 'assistant')
        .cast<Map>()
        .toList();
    check(
      assistant.length == 1 && assistant[0]['tool_calls'] is List,
      'compaction lost the assistant tool_calls line',
    );
    final firstCall =
        ((assistant[0]['tool_calls'] as List).first as Map)['function'] as Map;
    final firstArgs = jsonDecode(firstCall['arguments'] as String) as Map;
    check(
      firstArgs['path'] == 'big.txt',
      'a call without an intent must keep its input parameters: $firstArgs',
    );

    // Round 3: compaction persists, and the short result read AFTER the
    // gate stays raw — only the gate drops outputs.
    final round3 = fixture.toolMessages(fixture.requests[2]);
    check(round3.length == 2, 'round 3 carries ${round3.length} results');
    check(
      round3[0]['content'] == '',
      'round 3 lost the compacted big result',
    );
    check(
      round3[1]['content'] == 'tiny file body',
      'a result read after the gate must stay intact',
    );
    print('PASS compact mode (outputs dropped, calls keep their input)');
  } finally {
    await fixture.close();
  }
}

/// Case 2 — distill mode: the 3rd context-full event calls the
/// distiller once, persists knowledge/worklog/instruction through
/// [onDistilled], and resumes the run on a clean system +
/// CONTINUATION history that no longer carries tool payloads.
Future<void> testDistillMode() async {
  const agentName = 'distiller';
  const intention = 'survive three context-full events';
  const assignment = 'read big1.txt, big2.txt, big3.txt';

  final files = <String, String>{
    'big1.txt': 'A' * bigOutputChars,
    'big2.txt': 'B' * bigOutputChars,
    'big3.txt': 'C' * bigOutputChars,
  };
  final reads = <String>[];
  final tools = <ToolDef>[FixtureFileTool(files, reads)];

  DistillationProducts? distilled;
  var distilledCalls = 0;
  String? status;
  String? report;
  List<Map<String, dynamic>>? lastHistory;

  final fixture = await OpenAiFixture.start(
    pathForRound: (round) => 'big$round.txt',
    toolRounds: 3,
    finalAnswer: 'Distilled and resumed.',
  );
  try {
    final runner = _runner(
      fixture: fixture,
      tools: tools,
      agentName: agentName,
      intention: intention,
      assignment: assignment,
      contextCapacity: _capacityForGate(
        agentName: agentName,
        intention: intention,
        assignment: assignment,
      ),
      onDone: (s, r) {
        status = s;
        report = r;
      },
      onDistilled: (name, products) async {
        distilledCalls++;
        distilled = products;
      },
      onHistory: (history) => lastHistory = history,
    );
    await runner.start().timeout(const Duration(seconds: 10));

    check(
      status == 'completed' && report == 'Distilled and resumed.',
      'distill run did not complete: status=$status report=$report '
      'reads=$reads requests=${fixture.requests.length} error=${fixture.error}',
    );
    check(
      reads.join(',') == 'big1.txt,big2.txt,big3.txt',
      'distill run read the wrong files: $reads',
    );
    check(
      fixture.requests.length == 5,
      'expected 3 tool rounds + 1 distill + 1 resumed round = 5 requests, '
      'got ${fixture.requests.length}, error=${fixture.error}',
    );

    final distillRequest = fixture.requests.firstWhere(
      (body) =>
          body['messages'] is List &&
          (body['messages'] as List).isNotEmpty &&
          (body['messages'] as List).first is Map &&
          ((body['messages'] as List).first as Map)['content'] is String &&
          (((body['messages'] as List).first as Map)['content'] as String)
              .startsWith('You are the distillation pass'),
      orElse: () => <String, dynamic>{},
    );
    check(
      distillRequest.isNotEmpty,
      'no distillation request observed: ${fixture.requests.length} requests',
    );
    check(
      (distillRequest['tools'] == null ||
          (distillRequest['tools'] is List &&
              (distillRequest['tools'] as List).isEmpty)),
      'distillation request must not carry tools',
    );

    // The distill request proves the escalation order: the first two
    // context-full events already dropped big1/big2 outputs, while the
    // third (big3) was read after the gate and rides along raw for the
    // distillation pass to read.
    final distillHistory = fixture.toolMessages(distillRequest);
    check(
      distillHistory.length == 3,
      'distill request carries ${distillHistory.length} tool results',
    );
    check(
      distillHistory[0]['content'] == '' && distillHistory[1]['content'] == '',
      'the first two context-full events did not drop the outputs before distill',
    );
    check(
      distillHistory[2]['content'] == files['big3.txt'],
      'the third oversized payload must stay intact for the distiller',
    );

    check(distilledCalls == 1, 'onDistilled fired $distilledCalls times');
    check(
      distilled?.knowledge.contains('Fixture knowledge') == true &&
          distilled?.worklog.contains('Read three oversized') == true &&
          distilled?.instruction.contains('completion marker') == true,
      'distilled products were not parsed correctly: '
      'knowledge=${distilled?.knowledge} worklog=${distilled?.worklog} '
      'instruction=${distilled?.instruction}',
    );

    // The final request (after resume) must be exactly
    // [system, CONTINUATION] and carry no tool payloads.
    final resumed = fixture.requests.last;
    final messages = resumed['messages'] as List;
    check(
      messages.length == 2,
      'resumed request carries ${messages.length} messages (expected 2)',
    );
    final system = messages[0] as Map;
    final continuation = messages[1] as Map;
    check(system['role'] == 'system', 'resumed first message is not system');
    final systemText = '${system['content']}';
    check(
      systemText.contains('Fixture knowledge') &&
          systemText.contains('Read three oversized'),
      'resumed system prompt is missing distilled knowledge/worklog',
    );
    check(continuation['role'] == 'user', 'resumed second message is not user');
    final continuationText = '${continuation['content']}';
    check(
      continuationText.startsWith('===CONTINUATION==='),
      'resumed context is not the CONTINUATION block',
    );
    check(
      continuationText.contains('===INSTRUCTION===') &&
          continuationText.contains('completion marker'),
      'resumed CONTINUATION is missing the distilled instruction',
    );
    check(
      (resumed['messages'] as List).every((m) => (m as Map)['role'] != 'tool'),
      'resumed context still carries tool result messages',
    );

    // The recorded history at the end of the run is the resumed one,
    // proving the in-run handoff kept working on the clean context.
    check(
      lastHistory != null && lastHistory!.length == 2,
      'onHistory did not expose the resumed two-message context',
    );
    print('PASS distill mode (one distill call, clean CONTINUATION resume)');
  } finally {
    await fixture.close();
  }
}

Future<void> main() async {
  testCompactionRules();
  await testCompactMode();
  await testDistillMode();
  print('PASS both automatic context-compaction modes');
}
