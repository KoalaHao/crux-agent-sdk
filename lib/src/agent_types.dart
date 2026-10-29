import 'dart:convert';

import 'models/provider_config.dart';

/// Host-owned agent configuration. No database, terminal or platform binding.
class AgentProfile {
  final String model, domain, knowledge, worklog;
  const AgentProfile({
    required this.model,
    this.domain = 'general',
    this.knowledge = '',
    this.worklog = '',
  });
}

abstract interface class ProviderRegistry {
  ProviderConfig? providerByName(String name);
  String? getApiKey(String name);
}

/// Credentials are supplied by the host; this registry never reads config files.
class StaticProviderRegistry implements ProviderRegistry {
  final Map<String, ProviderConfig> providers;
  final Map<String, String> apiKeys;
  StaticProviderRegistry(
    Map<String, ProviderConfig> providers,
    Map<String, String> apiKeys,
  ) : providers = Map.unmodifiable(providers),
      apiKeys = Map.unmodifiable(apiKeys);
  factory StaticProviderRegistry.single(
    ProviderConfig provider,
    String apiKey,
  ) => StaticProviderRegistry(
    {provider.name: provider},
    {provider.name: apiKey},
  );
  @override
  ProviderConfig? providerByName(String name) => providers[name];
  @override
  String? getApiKey(String name) => apiKeys[name];
}

class AbortSignal {
  bool isAborted = false;
  void abort() {
    isAborted = true;
  }
}

/// Correlation identifiers and working directory are provided by the host.
/// Tool implementations remain responsible for authorization and path policy.
class ToolContext {
  final int sessionId, messageId;
  final String? callId;
  final AbortSignal abort;
  final String workingDirectory;
  ToolContext({
    required this.sessionId,
    required this.messageId,
    required this.abort,
    required this.workingDirectory,
    this.callId,
  });
}

class ToolResult {
  final String output;
  final bool failed;
  const ToolResult(this.output, {this.failed = false});
  factory ToolResult.error(String message) =>
      ToolResult(jsonEncode({'error': message}), failed: true);
}

abstract class ToolDef {
  String get name;
  String get description;
  Map<String, dynamic> get parametersSchema;
  Future<ToolResult> execute(Map<String, dynamic> input, ToolContext context);
}
