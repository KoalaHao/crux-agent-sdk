import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../models/provider_config.dart';
import '../models/credit_balance.dart';
import '../models/coding_plan_usage.dart';
import 'deepseek_balance_parser.dart';
import 'kimi_usage_parser.dart';
import 'zhipu_usage_parser.dart';

/// A one-shot account query. No timers, global credentials, or AgentRunner
/// coupling. Hosts own consent, refresh cadence and credential storage.
class ProviderAccountClient {
  final Duration timeout;
  const ProviderAccountClient({this.timeout = const Duration(seconds: 15)});

  Future<Object> fetch({
    required ProviderConfig provider,
    required String apiKey,
  }) async {
    if (apiKey.trim().isEmpty) throw const AccountQueryError('no_key');
    final base = Uri.parse(provider.endpointUrl);
    if (base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        !(base.scheme == 'https' ||
            (base.scheme == 'http' &&
                ['localhost', '127.0.0.1', '::1'].contains(base.host)))) {
      throw const AccountQueryError('invalid_endpoint');
    }
    final Uri url;
    switch (provider.type) {
      case 'deepseek':
      case 'deepseek_chat':
        url = base.replace(path: '/user/balance');
      case 'kimi':
        url = base.replace(
          path: '${base.path.replaceFirst(RegExp(r'/+$'), '')}/usages',
        );
      case 'zhipu':
        url = base.replace(path: '/api/monitor/usage/quota/limit');
      default:
        throw const AccountQueryError('unsupported');
    }
    final client = HttpClient();
    try {
      return await (() async {
        final request = await client.getUrl(url);
        request.followRedirects = false;
        request.headers.set(
          'Authorization',
          provider.type == 'zhipu' ? apiKey : 'Bearer $apiKey',
        );
        request.headers.set('Accept', 'application/json');
        request.headers.set('Accept-Language', 'en-US,en');
        request.headers.set('User-Agent', 'Crux-Agent-SDK/0.1');
        final response = await request.close();
        if (response.statusCode != 200) {
          throw AccountQueryError(switch (response.statusCode) {
            401 || 403 => 'unauthorized',
            404 => 'unavailable',
            429 => 'rate_limited',
            _ => 'http_error',
          }, response.statusCode);
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
          if (bytes.length > 1048576)
            throw const AccountQueryError('invalid_response');
        }
        final body = utf8.decode(bytes);
        try {
          return switch (provider.type) {
            'deepseek' || 'deepseek_chat' => parseDeepSeekBalanceResponse(
              body,
              providerName: provider.name,
            ),
            'kimi' => parseKimiUsageResponse(body, providerName: provider.name),
            _ => parseZhipuUsageResponse(body, providerName: provider.name),
          };
        } on CreditBalanceError {
          throw const AccountQueryError('invalid_response');
        } on CodingPlanUsageError {
          throw const AccountQueryError('invalid_response');
        } on FormatException {
          throw const AccountQueryError('invalid_response');
        }
      })().timeout(timeout);
    } on AccountQueryError {
      rethrow;
    } on TimeoutException {
      throw const AccountQueryError('timeout');
    } catch (_) {
      throw const AccountQueryError('network');
    } finally {
      client.close(force: true);
    }
  }
}

/// Deliberately excludes response bodies, URLs and credentials.
class AccountQueryError implements Exception {
  final String code;
  final int? status;
  const AccountQueryError(this.code, [this.status]);
  @override
  String toString() =>
      'AccountQueryError($code${status == null ? '' : ', $status'})';
}
