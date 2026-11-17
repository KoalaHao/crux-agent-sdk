/// A gateway that answers 200 with a JSON error envelope must not read as
/// an empty success. Plain `dart run test/gateway_body_test.dart`.
import 'package:crux_agent_sdk/crux_agent_sdk.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

void main() {
  final e = gatewayBodyError(
      line: '{"message":"系统内部错误，请联系管理员","success":false}');
  check(e != null, 'success:false is an error');
  check(e!.kind == LlmErrorKind.serverError, 'internal failure → serverError');
  check(e.message.contains('系统内部错误'), 'message survives verbatim');

  final coded = gatewayBodyError(line: '{"msg":"稍后重试","code":500}');
  check(coded?.kind == LlmErrorKind.serverError, 'code>=400 is an error');

  check(gatewayBodyError(line: '{"choices":[]}') == null, 'payload is not an error');
  check(gatewayBodyError(line: '{"output":[]}') == null, 'responses payload is not an error');
  check(gatewayBodyError(line: 'event: message_start') == null, 'an SSE line is not an error');
  check(gatewayBodyError(line: '{"type":"message"}') == null, 'a typed event is not an error');
  print('gateway_body_test passed');
}
