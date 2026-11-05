import 'dart:convert';
import 'dart:io';
import 'package:crux_agent_sdk/crux_agent_sdk.dart';
import 'package:crux_agent_sdk/src/services/llm_provider.dart';
import 'package:crux_agent_sdk/src/services/kimi_usage_parser.dart';
import 'package:crux_agent_sdk/src/services/zhipu_usage_parser.dart';

var count = 0;
void check(bool ok, String name) {
  if (!ok) throw StateError(name);
  count++;
  print('PASS $name');
}

Future<void> main() async {
  final oa = resolveProvider('openai').provider;
  var body = oa.buildRequestBody(
    'gpt-4.1',
    [],
    userId: 'private',
    maxTokens: 700,
  );
  check(
    !body.containsKey('thinking') &&
        !body.containsKey('user_id') &&
        !body.containsKey('reasoning_effort'),
    'OpenAI standard fields',
  );
  body = oa.buildRequestBody(
    'gpt-5.4',
    [],
    reasoningEffort: 'low',
    maxTokens: 800,
  );
  check(
    body['reasoning_effort'] == 'low' &&
        !body.containsKey('temperature') &&
        body['max_completion_tokens'] == 800,
    'OpenAI reasoning',
  );
  final ds = resolveProvider('deepseek_chat').provider;
  body = ds.buildRequestBody(
    'deepseek-flash',
    [],
    reasoningEffort: 'low',
    maxTokens: 900,
  );
  check(
    body['max_tokens'] == 900 &&
        body['reasoning_effort'] == 'low' &&
        !body.containsKey('temperature'),
    'DeepSeek current thinking',
  );
  body = ds.buildRequestBody(
    'deepseek-flash',
    [],
    thinkingMode: 'disabled',
    temperature: .4,
  );
  check(
    body['temperature'] == .4 &&
        (body['thinking'] as Map)['type'] == 'disabled',
    'DeepSeek nonthinking',
  );
  final kimi = resolveProvider('kimi').provider;
  body = kimi.buildRequestBody('k3-256k', [], maxTokens: 1234);
  check(
    body['model'] == 'k3-256k' &&
        body['max_completion_tokens'] == 1234 &&
        body['temperature'] == 1,
    'Kimi ID and output cap',
  );
  check(
    kimi.requestHeaders()['User-Agent']!.startsWith('Crux-Agent-SDK'),
    'honest client identity',
  );
  try {
    kimi.buildRequestBody('k3.1-pro', [], thinkingMode: 'disabled');
    throw StateError('accepted off');
  } on ArgumentError {
    count++;
  }
  final z = resolveProvider('zhipu').provider;
  body = z.buildRequestBody(
    'glm-5.3',
    [],
    maxTokens: 950,
    reasoningEffort: 'low',
  );
  check(
    body['max_tokens'] == 950 &&
        !body.containsKey('user_id') &&
        body['reasoning_effort'] == 'low',
    'GLM fields',
  );
  final short = {
    'window': {'duration': 300, 'timeUnit': 'MINUTE'},
    'detail': {'limit': 100, 'used': 20},
  };
  var usage = parseKimiUsageResponse(
    jsonEncode({
      'limits': [short],
    }),
  );
  check(
    usage.hasIntervalWindow &&
        !usage.hasWeeklyWindow &&
        usage.intervalRemainingPct == 80,
    'Kimi no invented weekly',
  );
  usage = parseKimiUsageResponse(
    jsonEncode({
      'usage': {'name': 'Weekly', 'limit': 100, 'used': 30},
    }),
  );
  check(
    !usage.hasIntervalWindow &&
        usage.hasWeeklyWindow &&
        usage.weeklyRemainingPct == 70,
    'Kimi summary only',
  );
  usage = parseKimiUsageResponse(
    jsonEncode({
      'limits': [short],
      'usage': {'limit': 100, 'used': 30},
    }),
  );
  check(
    usage.intervalRemainingPct == 80 && usage.weeklyRemainingPct == 70,
    'Kimi two windows',
  );
  usage = parseZhipuUsageResponse(
    jsonEncode({
      'code': 200,
      'data': {
        'limits': [
          {'type': 'TOKENS_LIMIT', 'unit': 3, 'percentage': 100},
        ],
      },
    }),
  );
  check(
    usage.hasIntervalWindow &&
        !usage.hasWeeklyWindow &&
        usage.intervalRemainingPct == 0,
    'GLM missing versus depleted',
  );
  for (final parse in [
    () => parseKimiUsageResponse('{"usage":{"limit":100}}'),
    () => parseZhipuUsageResponse(
      '{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3}]}}',
    ),
  ]) {
    try {
      parse();
      throw StateError('accepted missing counter');
    } on CodingPlanUsageError {
      count++;
    }
  }
  final server = await HttpServer.bind('127.0.0.1', 0);
  var status = 200,
      payload =
          '{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"12.50","granted_balance":"0","topped_up_balance":"12.50"}]}';
  String? auth, path;
  var requests = 0;
  server.listen((r) async {
    requests++;
    auth = r.headers.value('authorization');
    path = r.uri.path;
    r.response.statusCode = status;
    if (status == 302)
      r.response.headers.set(
        'location',
        'http://127.0.0.1:${server.port}/leak',
      );
    r.response.write(payload);
    await r.response.close();
  });
  ProviderConfig config(String type) => ProviderConfig(
    name: type,
    type: type,
    wireFamily: WireFamily.openaiCompatible,
    endpointUrl: 'http://127.0.0.1:${server.port}/v1',
    models: [],
  );
  const client = ProviderAccountClient();
  try {
    final balance =
        await client.fetch(
              provider: config('deepseek_chat'),
              apiKey: 'synthetic',
            )
            as CreditBalance;
    check(
      balance.primaryBalance!.totalBalance == '12.50' &&
          auth == 'Bearer synthetic' &&
          path == '/user/balance',
      'balance HTTP transport',
    );
    payload = jsonEncode({
      'limits': [short],
    });
    await client.fetch(provider: config('kimi'), apiKey: 'synthetic');
    check(
      path == '/v1/usages' && auth == 'Bearer synthetic',
      'Kimi usage transport',
    );
    payload =
        '{"code":200,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":6,"percentage":12}]}}';
    await client.fetch(provider: config('zhipu'), apiKey: 'synthetic');
    check(
      path == '/api/monitor/usage/quota/limit' && auth == 'synthetic',
      'GLM raw authentication',
    );
    for (final code in [401, 404, 429, 302]) {
      status = code;
      final before = requests;
      try {
        await client.fetch(provider: config('kimi'), apiKey: 'synthetic');
        throw StateError('accepted HTTP error');
      } on AccountQueryError catch (e) {
        check(
          e.status == code &&
              requests == before + 1 &&
              !e.toString().contains('synthetic'),
          'HTTP $code safe error / no redirect',
        );
      }
    }
    status = 200;
    payload = 'not-json-secret';
    try {
      await client.fetch(provider: config('kimi'), apiKey: 'synthetic');
      throw StateError('accepted malformed');
    } on AccountQueryError catch (e) {
      check(
        e.code == 'invalid_response' && !e.toString().contains('secret'),
        'sanitized parse failure',
      );
    }
    try {
      await client.fetch(provider: config('openai'), apiKey: 'synthetic');
      throw StateError('invented billing');
    } on AccountQueryError catch (e) {
      check(e.code == 'unsupported', 'OpenAI billing unsupported');
    }
  } finally {
    await server.close(force: true);
  }
  print('PASS $count provider/account checks');
}
