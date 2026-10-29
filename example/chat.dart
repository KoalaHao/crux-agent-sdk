import 'dart:io';
import 'package:crux_agent_sdk/crux_agent_sdk.dart';

Future<void> main(List<String> arguments) async {
  final key = Platform.environment['DEEPSEEK_API_KEY'];
  if (key == null || key.isEmpty) {
    stderr.writeln('Set DEEPSEEK_API_KEY in your environment.');
    exitCode = 2;
    return;
  }
  final prompt = arguments.isEmpty ? '你好，简单介绍一下自己。' : arguments.join(' ');
  final config = ProviderConfig(
    name: 'deepseek',
    type: 'openai_compatible',
    wireFamily: WireFamily.openaiCompatible,
    endpointUrl: 'https://api.deepseek.com',
    models: const [],
  );
  final runner = AgentRunner(
    agentName: 'assistant',
    profile: const AgentProfile(model: 'deepseek/deepseek-chat'),
    role: SubagentRole.worker,
    intention: 'conversation',
    message: prompt,
    initialHistory: [
      {'role': 'system', 'content': 'You are a helpful assistant.'},
      {'role': 'user', 'content': prompt},
    ],
    providerService: StaticProviderRegistry.single(config, key),
    toolExecutor: ToolExecutor(const []),
    tools: const [],
    sessionId: 1,
    workingDirectory: Directory.current.path,
    reasoningEffort: 'off',
    onChunk: (chunk) {
      if (chunk.textDelta != null) stdout.write(chunk.textDelta);
    },
    onDone: (status, report) {
      stdout.writeln();
      if (status != 'completed') {
        stderr.writeln('$status: $report');
        exitCode = 1;
      }
    },
  );
  final interrupt = ProcessSignal.sigint.watch().listen((_) {
    runner.cancel();
  });
  try {
    await runner.start();
  } finally {
    await interrupt.cancel();
  }
}
