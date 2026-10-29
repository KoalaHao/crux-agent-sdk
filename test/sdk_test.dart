import 'dart:async';
import 'dart:convert';
import 'package:crux_agent_sdk/crux_agent_sdk.dart';
import 'support/fixture_server.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

class MemoryTool extends ToolDef {
  @override
  final String name;
  final Map<String, String> files;
  final List<String> calls;
  MemoryTool(this.name, this.files, this.calls);
  @override
  String get description => '$name text in a test-only in-memory workspace';
  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'name': {'type': 'string'},
      if (name == 'write') 'text': {'type': 'string'},
    },
    'required': ['name', if (name == 'write') 'text'],
  };
  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input,
    ToolContext context,
  ) async {
    check(!context.abort.isAborted, 'cancelled tool dispatched');
    calls.add(name);
    if (name == 'write')
      files[input['name'] as String] = input['text'] as String;
    return ToolResult(
      jsonEncode({'name': input['name'], 'text': files[input['name']]}),
    );
  }
}

Future<void> main() async {
  for (final mode in ['normal', 'malformed', 'http_error', 'stall']) {
    final server = await FixtureServer.start(mode: mode);
    final files = <String, String>{};
    final calls = <String>[];
    final tools = [
      MemoryTool('write', files, calls),
      MemoryTool('read', files, calls),
    ];
    String? status;
    String? report;
    var doneCount = 0;
    var text = '';
    final ready = Completer<void>();
    final config = ProviderConfig(
      name: 'fixture',
      type: 'openai_compatible',
      wireFamily: WireFamily.openaiCompatible,
      endpointUrl: server.endpoint,
      models: const [],
    );
    final runner = AgentRunner(
      agentName: 'test',
      profile: const AgentProfile(model: 'fixture/model'),
      role: SubagentRole.worker,
      intention: 'write then read',
      message: 'write then read',
      providerService: StaticProviderRegistry.single(config, 'fixture-only'),
      tools: tools,
      toolExecutor: ToolExecutor(tools),
      sessionId: 1,
      workingDirectory: '.',
      reasoningEffort: 'off',
      maxRounds: 8,
      onStatus: (_) {
        if (!ready.isCompleted) ready.complete();
      },
      onChunk: (chunk) {
        text += chunk.textDelta ?? '';
      },
      onDone: (s, r) {
        status = s;
        report = r;
        doneCount++;
      },
    );
    try {
      final running = runner.start();
      if (mode == 'stall') {
        await ready.future;
        await Future<void>.delayed(const Duration(milliseconds: 60));
        runner.cancel();
      }
      await running.timeout(const Duration(seconds: 5));
      check(doneCount == 1, '$mode completed more than once');
      if (mode == 'normal') {
        check(
          status == 'completed' && report == 'Tool roundtrip completed.',
          'normal response failed',
        );
        check(text == report, 'stream delta mismatch');
        check(calls.join(',') == 'write,read', 'wrong tool sequence');
        check(
          server.requests.length == 3 && server.error == null,
          'prefix/tool pairing failed: ${server.error}',
        );
      } else if (mode == 'stall') {
        check(status == 'cancelled', 'cancel did not terminate');
      } else if (mode == 'http_error') {
        check(status == 'failed', 'HTTP error treated as success');
      } else {
        check(
          calls.isEmpty && files.isEmpty,
          'malformed streamed arguments executed a tool',
        );
      }
      print('PASS SDK $mode');
    } finally {
      await server.close();
    }
  }
  final context = ToolContext(
    sessionId: 1,
    messageId: 1,
    abort: AbortSignal(),
    workingDirectory: '.',
  );
  final unknown = await ToolExecutor(const []).executeTool(
    const ToolCall(callId: 'x', name: 'missing', input: {}),
    context,
  );
  check(unknown.failed, 'unknown tool accepted');
  print('PASS host-injected tools and unknown-tool refusal');
}
