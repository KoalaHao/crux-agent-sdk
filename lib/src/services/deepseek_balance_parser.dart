import 'dart:convert';
import '../models/credit_balance.dart';

CreditBalance parseDeepSeekBalanceResponse(
  String body, {
  String providerName = 'deepseek',
}) {
  final dynamic decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException catch (e) {
    throw CreditBalanceError(
      CreditBalanceErrorKind.parse,
      'Invalid JSON: ${e.message}',
    );
  }
  if (decoded is! Map<String, dynamic>) {
    throw const CreditBalanceError(
      CreditBalanceErrorKind.parse,
      'Response root is not a JSON object',
    );
  }

  final isAvailable = decoded['is_available'];
  if (isAvailable is! bool) {
    throw const CreditBalanceError(
      CreditBalanceErrorKind.parse,
      'Missing or invalid is_available field',
    );
  }

  final infosRaw = decoded['balance_infos'];
  if (infosRaw is! List || infosRaw.isEmpty) {
    throw const CreditBalanceError(
      CreditBalanceErrorKind.parse,
      'Missing or empty balance_infos array',
    );
  }

  final infos = <BalanceInfo>[];
  for (final entry in infosRaw) {
    if (entry is! Map<String, dynamic>)
      throw const CreditBalanceError(
        CreditBalanceErrorKind.parse,
        'Malformed balance entry',
      );
    final currency = entry['currency'];
    final total = entry['total_balance'];
    final granted = entry['granted_balance'];
    final toppedUp = entry['topped_up_balance'];
    if (currency is! String ||
        total is! String ||
        granted is! String ||
        toppedUp is! String) {
      throw const CreditBalanceError(
        CreditBalanceErrorKind.parse,
        'Malformed balance_infos entry',
      );
    }
    infos.add(
      BalanceInfo(
        currency: currency,
        totalBalance: total,
        grantedBalance: granted,
        toppedUpBalance: toppedUp,
      ),
    );
  }

  return CreditBalance(
    providerName: providerName,
    isAvailable: isAvailable,
    balanceInfos: infos,
    fetchedAt: DateTime.now(),
  );
}
