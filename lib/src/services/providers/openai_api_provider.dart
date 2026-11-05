import 'openai_compatible_provider.dart';

/// Official OpenAI Chat Completions API, distinct from Codex subscriptions
/// and third-party extensions to the OpenAI-compatible protocol.
class OpenAIApiProvider extends OpenAICompatibleProvider {
  @override
  String get name => 'openai';

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
    body.remove('thinking');
    body.remove('user_id');
    body.remove('reasoning_effort');
    final reasoning =
        modelId.startsWith('gpt-5') || RegExp(r'^o[1-9]').hasMatch(modelId);
    if (reasoning) {
      // Sampling support differs between reasoning models; omit both knobs.
      body.remove('temperature');
      body.remove('top_p');
      if (thinkingMode != 'disabled' && reasoningEffort != null) {
        body['reasoning_effort'] = switch (reasoningEffort) {
          'normal' => 'medium',
          'max' => 'high',
          _ => reasoningEffort,
        };
      }
      // Off means provider default here: some models cannot disable reasoning.
    }
    return body;
  }
}
