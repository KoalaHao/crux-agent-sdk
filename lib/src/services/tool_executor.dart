import 'dart:convert';
import '../models/provider_config.dart';
import '../services/llm_client.dart';
import '../agent_types.dart';

class ToolCall {
  final String callId;
  final String name;
  final Map<String, dynamic> input;
  final String? parseError;

  const ToolCall({
    required this.callId,
    required this.name,
    required this.input,
    this.parseError,
  });
}

class _ToolCallAccum {
  String? callId;
  String? name;
  final StringBuffer inputBuffer = StringBuffer();
}

class ToolExecutor {
  final List<ToolDef> tools;
  final void Function(ToolCall call)? beforeExecute;
  final void Function(ToolCall call, ToolResult result)? afterExecute;
  ToolExecutor(this.tools, {this.beforeExecute, this.afterExecute});
  Future<ToolResult> executeTool(ToolCall call, ToolContext context) async {
    if (context.abort.isAborted) return ToolResult.error("Cancelled");
    if (call.parseError != null) return ToolResult.error(call.parseError!);
    for (final tool in tools) {
      if (tool.name == call.name) {
        beforeExecute?.call(call);
        final result = await tool.execute(call.input, context);
        afterExecute?.call(call, result);
        return result;
      }
    }
    return ToolResult.error("Unknown tool: ${call.name}");
  }
  Map<String, dynamic> formatToolResultForApi(
    ToolCall call,
    ToolResult result,
    WireFamily wireFamily,
  ) {
    if (wireFamily == WireFamily.anthropicCompatible) {
      return {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': call.callId,
            'content': result.output,
          },
        ],
      };
    }
    return {
      'role': 'tool',
      'tool_call_id': call.callId,
      'content': result.output,
    };
  }

  Map<String, dynamic> formatAssistantToolCallsMessage(
    List<ToolCall> calls,
    String textContent,
    WireFamily wireFamily, {
    String reasoningContent = '',
    String reasoningSignature = '',
  }) {
    if (wireFamily == WireFamily.anthropicCompatible) {
      final content = <Map<String, dynamic>>[];
      if (reasoningContent.isNotEmpty && reasoningSignature.isNotEmpty) {
        content.add({
          'type': 'thinking',
          'thinking': reasoningContent,
          'signature': reasoningSignature,
        });
      }
      if (textContent.isNotEmpty) {
        content.add({'type': 'text', 'text': textContent});
      }
      for (final call in calls) {
        content.add({
          'type': 'tool_use',
          'id': call.callId,
          'name': call.name,
          'input': call.input,
        });
      }
      return {'role': 'assistant', 'content': content};
    }
    final toolCalls = calls
        .map(
          (call) => {
            'id': call.callId,
            'type': 'function',
            'function': {
              'name': call.name,
              'arguments': jsonEncode(call.input),
            },
          },
        )
        .toList();
    return {
      'role': 'assistant',
      'content': textContent.isNotEmpty ? textContent : null,
      // Responses API (DeepSeek) requires the assistant's CoT to be
      // passed back on tool-call rounds — without it the API 400s
      // ("The reasoning_text in the thinking mode must be passed back
      // to the API"). This is the in-agentic-loop message ChatService
      // adds on rounds 2+, so it bypasses buildApiMessages; carry the
      // reasoning here or the follow-up request dies on round 2.
      if (wireFamily == WireFamily.responsesApi && reasoningContent.isNotEmpty)
        'reasoning_content': reasoningContent,
      'tool_calls': toolCalls,
    };
  }

  static List<ToolCall> parseToolUseFromChunks(List<LlmChunk> chunks) {
    final groups = <int, _ToolCallAccum>{};

    for (final chunk in chunks) {
      if (chunk.toolUse != null) {
        final tu = chunk.toolUse!;
        final idx = tu.index;
        final acc = groups.putIfAbsent(idx, () => _ToolCallAccum());
        if (tu.callId.isNotEmpty) acc.callId = tu.callId;
        if (tu.name.isNotEmpty) acc.name = tu.name;
        acc.inputBuffer.write(tu.inputDelta);
      }
    }

    final calls = <ToolCall>[];
    for (final idx in groups.keys.toList()..sort()) {
      final acc = groups[idx]!;
      if (acc.callId == null || acc.name == null) continue;
      Map<String, dynamic> input = {};
      String? parseError;
      try {
        final raw = acc.inputBuffer.toString();
        if (raw.isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) {
            input = decoded;
          } else {
            parseError =
                'Tool input must be a JSON object, got ${decoded.runtimeType}';
          }
        }
      } catch (e) {
        parseError = 'Failed to parse tool input JSON: $e';
      }
      calls.add(
        ToolCall(
          callId: acc.callId!,
          name: acc.name!,
          input: input,
          parseError: parseError,
        ),
      );
    }
    return calls;
  }

  static String? parseFinishReason(List<LlmChunk> chunks) {
    for (final chunk in chunks) {
      if (chunk.finishReason != null) {
        final reason = chunk.finishReason!;
        if (reason == 'tool_use' || reason == 'tool_calls') return 'tool_use';
        if (reason == 'end_turn' || reason == 'stop') return 'stop';
        if (reason == 'done') return 'done';
        return reason;
      }
    }
    return null;
  }
}
