import 'dart:convert';

import 'package:crux_agent_sdk/src/services/llm_provider.dart';

void main() {
  for (final providerName in ['deepseek', 'codex']) {
    final provider = resolveProvider(providerName).provider;
    final body = provider.buildRequestBody('fixture-model', [
      {'role': 'system', 'content': 'Instructions'},
      {'role': 'user', 'content': 'First turn'},
      {
        'role': 'assistant',
        'content': 'Calling a tool',
        'tool_calls': [
          {
            'id': 'call-1',
            'function': {'name': 'lookup', 'arguments': '{}'},
          },
        ],
      },
      {'role': 'tool', 'tool_call_id': 'call-1', 'content': 'Result'},
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'Next turn'},
          {
            'type': 'image_url',
            'image_url': {'url': 'https://example.com/image.png'},
          },
        ],
      },
    ]);
    // Decode the serialized wire body, as a strict Responses gateway does.
    final input = (jsonDecode(jsonEncode(body)) as Map)['input'] as List;
    final types = input.map((item) => item['type']).toList();
    if (jsonEncode(types) !=
        jsonEncode([
          'message',
          'message',
          'function_call',
          'function_call_output',
          'message',
        ])) {
      throw StateError(
        '$providerName input items must have explicit types: $types',
      );
    }
    if (input[0]['content'][0]['type'] != 'input_text' ||
        input[1]['content'][0]['type'] != 'output_text' ||
        input[4]['content'][1]['type'] != 'input_image') {
      throw StateError('$providerName changed message content types');
    }
    print('PASS $providerName explicit Responses input types');
  }
}
