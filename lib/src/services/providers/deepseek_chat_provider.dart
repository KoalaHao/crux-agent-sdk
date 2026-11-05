import 'openai_compatible_provider.dart';

/// DeepSeek's documented Chat Completions interface. The existing `deepseek`
/// type retains its Responses API protocol for backward compatibility.
class DeepSeekChatProvider extends OpenAICompatibleProvider {
  @override
  String get name => 'deepseek_chat';
  @override
  String mapEffort(String? effort) => switch (effort) {
    'low' || 'minimal' => 'low',
    'max' => 'max',
    _ => 'high',
  };
  @override
  Map<String, dynamic> buildRequestBody(
    String modelId,
    List<Map<String, dynamic>> messages, {
    String thinkingMode = 'enabled',
    String? reasoningEffort,
    int? thinkingBudget,
    int? maxTokens,
    double temperature = 0,
    double topP = 1,
    List<Map<String, dynamic>>? tools,
    String? userId,
  }) {
    final body = super.buildRequestBody(
      modelId,
      messages,
      thinkingMode: thinkingMode,
      reasoningEffort: reasoningEffort,
      maxTokens: maxTokens,
      temperature: temperature,
      topP: topP,
      tools: tools,
    );
    body.remove('user_id');
    final cap = body.remove('max_completion_tokens');
    if (cap != null) body['max_tokens'] = cap;
    if (thinkingMode != 'disabled') {
      body.remove('temperature');
      body.remove('top_p');
    }
    return body;
  }
}
