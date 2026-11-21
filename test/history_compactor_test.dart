import 'dart:convert';

import 'package:crux_agent_sdk/src/services/subagent/history_compactor.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

const int bigOutputChars = 20000;

/// Case 1 — OpenAI-compatible wire: a tool call carrying `intent`
/// keeps ONLY the intent; the result message survives with its
/// `tool_call_id` but its output is blanked.
void testOpenAiIntent() {
  final history = <Map<String, dynamic>>[
    {
      'role': 'assistant',
      'content': null,
      'tool_calls': [
        {
          'id': 'call_1',
          'type': 'function',
          'function': {
            'name': 'edit',
            'arguments': jsonEncode({
              'filePath': 'lib/foo.dart',
              'oldString': 'class Foo {}',
              'newString': 'class Bar {}',
              'intent': 'rename the class',
            }),
          },
        },
      ],
    },
    {'role': 'tool', 'tool_call_id': 'call_1', 'content': 'X' * bigOutputChars},
  ];

  compactToolHistory(history);

  final call = (history[0]['tool_calls'] as List).single as Map;
  final function = call['function'] as Map;
  final arguments =
      jsonDecode(function['arguments'] as String) as Map<String, dynamic>;
  check(
    arguments.length == 1 && arguments['intent'] == 'rename the class',
    'tool call with intent must keep only the intent, got $arguments',
  );
  check(
    !arguments.containsKey('filePath') &&
        !arguments.containsKey('oldString') &&
        !arguments.containsKey('newString'),
    'tool call with intent must drop the other input params',
  );
  final result = history[1];
  check(
    result['content'] == '',
    'tool output must be blanked, got ${result['content']}',
  );
  check(
    result['tool_call_id'] == 'call_1',
    'tool result must keep its tool_call_id for wire pairing',
  );
  print('PASS OpenAI wire — intent kept, output dropped');
}

/// Case 2 — Anthropic-compatible wire: a tool call WITHOUT `intent`
/// keeps its input parameters verbatim; the `tool_result` block keeps
/// its `tool_use_id` but its output is blanked.
void testAnthropicInputArgs() {
  final history = <Map<String, dynamic>>[
    {
      'role': 'assistant',
      'content': [
        {'type': 'text', 'text': 'working'},
        {
          'type': 'tool_use',
          'id': 'toolu_1',
          'name': 'read',
          'input': {'filePath': 'lib/foo.dart', 'offset': 10, 'limit': 50},
        },
      ],
    },
    {
      'role': 'user',
      'content': [
        {
          'type': 'tool_result',
          'tool_use_id': 'toolu_1',
          'content': 'Y' * bigOutputChars,
        },
        {'type': 'text', 'text': 'keep going'},
      ],
    },
  ];

  compactToolHistory(history);

  final blocks = (history[0]['content'] as List).cast<Map>();
  final use = blocks.firstWhere((b) => b['type'] == 'tool_use');
  final input = use['input'] as Map;
  check(
    input['filePath'] == 'lib/foo.dart' &&
        input['offset'] == 10 &&
        input['limit'] == 50,
    'tool call without intent must keep its input params, got $input',
  );
  check(
    input.length == 3,
    'tool call without intent must not gain or lose params',
  );
  check(use['id'] == 'toolu_1', 'tool_use id must survive');

  final resultBlocks = (history[1]['content'] as List).cast<Map>();
  final result = resultBlocks.firstWhere((b) => b['type'] == 'tool_result');
  check(
    result['content'] == '',
    'tool result output must be blanked, got ${result['content']}',
  );
  check(
    result['tool_use_id'] == 'toolu_1',
    'tool_result must keep its tool_use_id for wire pairing',
  );
  final text = resultBlocks.firstWhere((b) => b['type'] == 'text');
  check(text['text'] == 'keep going', 'non-tool blocks must be untouched');
  print('PASS Anthropic wire — input params kept, output dropped');
}

void main() {
  testOpenAiIntent();
  testAnthropicInputArgs();
  print('PASS both tool-call compaction branches');
}
