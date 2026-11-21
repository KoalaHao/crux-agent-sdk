import 'dart:convert';

/// Stage-1/2 automatic context compaction.
///
/// The rule is about the tool CALL, not the tool output:
///
///  * a tool call that carries a non-empty `intent` keeps only that
///    `intent`;
///  * a tool call without an `intent` keeps its input parameters
///    unchanged;
///  * the tool output is never kept — every tool result payload is
///    blanked, while the message/block that carries the result stays
///    in place so the wire-protocol pairing (`tool_call_id` on
///    OpenAI, `tool_use_id` on Anthropic) remains valid.
///
/// Works in place on the canonical history shape used by
/// [AgentRunner], which is a list of `{role, content, ...}` maps:
///
///  * OpenAI-compatible calls: `assistant.tool_calls[].function.arguments`
///    (a JSON string) and `role: tool` result messages;
///  * Anthropic-compatible calls: `assistant.content[]` blocks of
///    `type: tool_use` with an `input` map, answered by `user.content[]`
///    blocks of `type: tool_result`.
void compactToolHistory(List<Map<String, dynamic>> history) {
  for (final message in history) {
    final role = message['role'];
    if (role == 'assistant') {
      _compactAssistantCalls(message);
    } else if (role == 'tool') {
      // OpenAI-compatible tool result. Keep the message (and its
      // tool_call_id) so the call still has a response, but drop the
      // output itself.
      if (message['content'] is String) message['content'] = '';
    } else if (role == 'user') {
      _blankToolResultBlocks(message);
    }
  }
}

void _compactAssistantCalls(Map<String, dynamic> message) {
  // OpenAI-compatible: tool_calls[].function.arguments is a JSON string.
  final toolCalls = message['tool_calls'];
  if (toolCalls is List) {
    for (final call in toolCalls) {
      if (call is! Map) continue;
      final function = call['function'];
      if (function is! Map) continue;
      final arguments = function['arguments'];
      if (arguments is! String) continue;
      function['arguments'] = _compactArguments(arguments);
    }
  }

  // Anthropic-compatible: assistant.content[] tool_use blocks carry
  // the arguments as an `input` map.
  final content = message['content'];
  if (content is List) {
    for (final block in content) {
      if (block is! Map || block['type'] != 'tool_use') continue;
      final input = block['input'];
      if (input is Map) {
        block['input'] = _compactInput(Map<String, dynamic>.from(input));
      }
    }
  }
}

void _blankToolResultBlocks(Map<String, dynamic> message) {
  final content = message['content'];
  if (content is! List) return;
  for (final block in content) {
    if (block is! Map || block['type'] != 'tool_result') continue;
    // Keep the block + tool_use_id; drop only the output.
    block['content'] = '';
  }
}

String _compactArguments(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      return jsonEncode(_compactInput(Map<String, dynamic>.from(decoded)));
    }
  } catch (_) {
    // Malformed arguments are left untouched — this pass must never
    // make an already-broken call worse.
  }
  return raw;
}

Map<String, dynamic> _compactInput(Map<String, dynamic> input) {
  final intent = input['intent'];
  if (intent is String && intent.trim().isNotEmpty) {
    return <String, dynamic>{'intent': intent};
  }
  return input;
}
