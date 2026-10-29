import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/coding_plan_usage.dart';
import '../../models/provider_config.dart';
import '../codex_oauth.dart';
import 'deepseek_provider.dart';
import 'coding_plan_provider.dart';

/// Normalizes both the legacy `/wham/usage` shape and the newer multi-bucket
/// Codex rate-limit shape into Crux's two-window coding-plan display.
///
/// ChatGPT's current response may provide `primary`/`secondary` directly, or
/// put them under `rateLimitsByLimitId` / `additional_rate_limits`. Selecting
/// by window length keeps the five-hour and weekly readouts intact when extra
/// per-model buckets are present.
CodingPlanUsage parseCodexCodingPlanUsage(
  Map<String, dynamic> root, {
  DateTime? now,
}) {
  final fetchedAt = now ?? DateTime.now();
  final windows = <Map<String, dynamic>>[];

  void addWindow(dynamic value) {
    if (value is! Map) return;
    final window = Map<String, dynamic>.from(value);
    if (window['used_percent'] is num || window['usedPercent'] is num) {
      windows.add(window);
    }
  }

  void collect(dynamic value) {
    if (value is List) {
      for (final item in value) {
        collect(item);
      }
      return;
    }
    if (value is! Map) return;
    final map = Map<String, dynamic>.from(value);
    addWindow(map);
    addWindow(map['primary']);
    addWindow(map['secondary']);
    addWindow(map['primary_window']);
    addWindow(map['secondary_window']);
    for (final entry in map.values) {
      if (entry is Map) {
        final nested = Map<String, dynamic>.from(entry);
        addWindow(nested['primary']);
        addWindow(nested['secondary']);
        addWindow(nested['primary_window']);
        addWindow(nested['secondary_window']);
      }
    }
  }

  collect(root['rate_limit']);
  collect(root['rate_limits']);
  collect(root['rateLimits']);
  collect(root['rateLimitsByLimitId']);
  collect(root['additional_rate_limits']);
  if (windows.isEmpty) {
    throw const CodingPlanUsageError(
      CodingPlanUsageErrorKind.parse,
      'Codex usage response has no rate-limit windows',
    );
  }

  int minutes(Map<String, dynamic> window) {
    final value =
        window['window_minutes'] ??
        window['windowMinutes'] ??
        window['windowDurationMins'];
    if (value is num) return value.round();
    final seconds =
        window['limit_window_seconds'] ?? window['limitWindowSeconds'];
    return seconds is num ? (seconds / 60).round() : 0;
  }

  // The short window is normally 300 minutes and the long one is normally a
  // week. Prefer those ranges but retain a useful display for plans with only
  // a single bucket or a different server-defined duration.
  final shortWindows = windows
      .where((window) => minutes(window) > 0 && minutes(window) <= 12 * 60)
      .toList(growable: false);
  final short = shortWindows.fold<Map<String, dynamic>?>(null, (best, window) {
    if (best == null) return window;
    return (minutes(window) - 300).abs() < (minutes(best) - 300).abs()
        ? window
        : best;
  });
  final weeklyWindows = windows
      .where((window) => minutes(window) >= 24 * 60)
      .toList(growable: false);
  final weekly = weeklyWindows.fold<Map<String, dynamic>?>(
    null,
    (best, window) =>
        best == null || minutes(window) > minutes(best) ? window : best,
  );
  // Keep the generic percentage fields populated for callers that predate
  // optional windows, but make visibility explicit. In particular, do not
  // duplicate a weekly-only Codex limit under the misleading "5h" label.
  final fallbackInterval = windows.first;
  final fallbackWeekly = windows.length > 1 ? windows[1] : fallbackInterval;
  final intervalWindow = short ?? weekly ?? fallbackInterval;
  final weeklyWindow = weekly ?? short ?? fallbackWeekly;

  int remaining(Map<String, dynamic> window) =>
      (100 - ((window['used_percent'] ?? window['usedPercent']) as num).round())
          .clamp(0, 100);
  Duration? reset(Map<String, dynamic> window) {
    final seconds =
        window['resets_at'] ??
        window['resetsAt'] ??
        window['reset_at'] ??
        window['resetAt'];
    if (seconds is num) {
      final at = DateTime.fromMillisecondsSinceEpoch(seconds.toInt() * 1000);
      return at.difference(fetchedAt).isNegative
          ? Duration.zero
          : at.difference(fetchedAt);
    }
    final after = window['reset_after_seconds'] ?? window['resetAfterSeconds'];
    return after is num ? Duration(seconds: after.round()) : null;
  }

  return CodingPlanUsage(
    providerName: 'codex',
    modelName: 'codex',
    intervalRemainingPct: remaining(intervalWindow),
    weeklyRemainingPct: remaining(weeklyWindow),
    intervalRemains: reset(intervalWindow),
    weeklyRemains: reset(weeklyWindow),
    // Older / workspace-scoped responses can omit duration metadata. In that
    // case retain the legacy two-window presentation rather than hiding the
    // complete usage display. When either duration is known, only show the
    // windows we can identify truthfully.
    hasIntervalWindow: short != null || weekly == null,
    hasWeeklyWindow: weekly != null || short == null,
    fetchedAt: fetchedAt,
  );
}

/// ChatGPT Codex provider.
///
/// This mirrors OpenCode's Codex auth plugin at the HTTP boundary: requests
/// use the OpenAI Responses input-item format but are sent to ChatGPT's Codex
/// backend with an OAuth access token in the normal Bearer slot. The backend
/// does not accept the sampling knobs or caller-selected output cap that the
/// public API accepts, so they are deliberately omitted.
///
/// Configure the current ChatGPT OAuth access token with
/// `/provider codex <token>`. Crux persists it as a provider credential; its
/// normal API-key environment override is `CRUX_API_KEY_CODEX`.
class CodexProvider extends DeepSeekProvider with CodingPlanProvider {
  String? _accountId;

  @override
  String get name => 'codex';

  @override
  WireFamily get wire => WireFamily.responsesApi;

  @override
  AuthStyle get authStyle => AuthStyle.bearer;

  /// Codex reuses DeepSeek's Responses API request implementation, but the
  /// inherited provider also carries DeepSeek's `/user/balance` machinery.
  /// ChatGPT Codex exposes subscription quota windows instead, which this
  /// class surfaces through [CodingPlanProvider]. Keep the credit capability
  /// disabled so the UI never renders a DeepSeek balance cell or polls that
  /// endpoint with a Codex OAuth credential.
  @override
  bool get isCreditBalance => false;

  @override
  String canonicalModelId(String modelId) => switch (modelId) {
    'gpt-5.5-codex' || 'gpt-5.6-codex' => 'gpt-5.6-sol',
    _ => modelId,
  };

  /// Crux's five-level UI maps cleanly to the Responses API's effort names.
  /// `max` maps to the strongest Codex level while preserving compatibility
  /// with models that treat it as an alias for `high`.
  @override
  String mapEffort(String? effort) {
    switch (effort) {
      case 'low':
        return 'low';
      case 'normal':
        return 'medium';
      case 'max':
        return 'xhigh';
      case 'high':
      default:
        return 'high';
    }
  }

  @override
  Map<String, String> requestHeaders({String? userId}) {
    final headers = <String, String>{
      'originator': 'crux',
      'User-Agent': 'crux',
      // Keep a stable identifier across one Crux chat. The standard chat
      // executor supplies its install-scoped session id as `userId`.
      'session-id': userId ?? 'crux-auxiliary',
    };
    final accountId = _accountId;
    if (accountId != null && accountId.isNotEmpty) {
      headers['ChatGPT-Account-Id'] = accountId;
    }
    return headers;
  }

  @override
  Future<String> resolveApiKey(String apiKey) async {
    final credential = CodexCredential.decode(apiKey);
    _accountId =
        credential?.accountId ??
        (credential == null
            ? CodexCredential.extractAccountId(apiKey)
            : CodexCredential.extractAccountId(credential.accessToken));
    if (credential == null ||
        credential.expiresAt.isAfter(
          DateTime.now().add(const Duration(minutes: 2)),
        )) {
      return credential?.accessToken ?? apiKey;
    }
    final refreshed = await CodexOAuth.refresh(
      credential.refreshToken,
      accountId: _accountId,
    );
    final refreshedCredential = CodexCredential.decode(refreshed)!;
    _accountId =
        refreshedCredential.accountId ??
        CodexCredential.extractAccountId(refreshedCredential.accessToken) ??
        _accountId;
    // The provider service persists the encoded credential. A refreshed token
    // remains valid for this request; the next device login replaces storage.
    return refreshedCredential.accessToken;
  }

  String? _credential;

  @override
  void startCodingPlanPolling({
    required String apiKey,
    Duration? interval,
    String? baseUrl,
  }) {
    _credential = apiKey;
    super.startCodingPlanPolling(
      apiKey: apiKey,
      interval: interval,
      baseUrl: baseUrl,
    );
  }

  @override
  void stopCodingPlanPolling() {
    super.stopCodingPlanPolling();
    _credential = null;
  }

  /// ChatGPT exposes Codex subscription limits as used percentages. Convert
  /// the primary window and (when available) secondary window into the
  /// generic CodingPlanUsage surface used by Crux's toolbar and home widget.
  @override
  Future<CodingPlanUsage> getCodingPlanUsage() async {
    final raw = _credential;
    if (raw == null) {
      throw const CodingPlanUsageError(
        CodingPlanUsageErrorKind.noApiKey,
        'Codex is not signed in',
      );
    }
    final token = await resolveApiKey(raw);
    return _readRateLimitsFromLegacyEndpoint(token);
  }

  Future<CodingPlanUsage> _readRateLimitsFromLegacyEndpoint(
    String token,
  ) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('https://chatgpt.com/backend-api/wham/usage'),
      );
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      // Usage is scoped to the same ChatGPT workspace as Responses calls.
      // Omitting ChatGPT-Account-Id here can make this endpoint return a
      // default/empty quota view even though the chat request is correctly
      // rate-limited for the signed-in workspace.
      for (final entry in requestHeaders().entries) {
        request.headers.set(entry.key, entry.value);
      }
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        throw CodingPlanUsageError(
          CodingPlanUsageErrorKind.network,
          'Codex usage request failed (HTTP ${response.statusCode})',
        );
      }
      return parseCodexCodingPlanUsage(
        jsonDecode(body) as Map<String, dynamic>,
      );
    } on TimeoutException {
      throw const CodingPlanUsageError(
        CodingPlanUsageErrorKind.network,
        'Codex usage request timed out',
      );
    } finally {
      client.close(force: true);
    }
  }

  @override
  Map<String, dynamic> buildRequestBody(
    String modelId,
    List<Map<String, dynamic>> messages, {
    String thinkingMode = 'enabled',
    String? reasoningEffort,
    int? thinkingBudget,
    int? maxTokens,
    double temperature = 0,
    double topP = 1.0,
    List<Map<String, dynamic>>? tools,
    String? userId,
  }) {
    final body = super.buildRequestBody(
      modelId,
      messages,
      thinkingMode: thinkingMode,
      reasoningEffort: reasoningEffort,
      thinkingBudget: thinkingBudget,
      maxTokens: maxTokens,
      temperature: temperature,
      topP: topP,
      tools: tools,
      userId: userId,
    );
    // ChatGPT's Codex backend requires stateless Responses requests. This is
    // deliberately Codex-only: public OpenAI API providers retain their own
    // storage policy.
    body['store'] = false;
    body
      ..remove('temperature')
      ..remove('top_p')
      ..remove('max_output_tokens')
      ..remove('user');
    return body;
  }
}
