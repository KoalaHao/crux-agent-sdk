import '../../models/provider_config.dart';
import 'deepseek_provider.dart';

/// Generic OpenAI Responses API provider (``<base>/responses``).
///
/// DeepSeek's provider already converts the OpenAI-IR message list into
/// Responses input items; the only vendor-specific piece is the effort
/// mapping and the credit-balance endpoint. This subclass keeps the wire
/// conversion, passes the effort through verbatim so a host's own reasoning
/// ladder is honoured, and opts out of the DeepSeek-only account query.
class ResponsesApiProvider extends DeepSeekProvider {
  @override
  String get name => 'responses';

  @override
  WireFamily get wire => WireFamily.responsesApi;

  @override
  bool get isCreditBalance => false;

  @override
  String mapEffort(String? effort) => effort ?? 'high';
}
