import 'dart:async';
import 'dart:convert';
import 'dart:io';

// A clearly labeled deterministic HTTP/SSE fixture. It exercises the real
// Crux parser and tool loop; it is never counted as a cloud-model response.
class FixtureServer {
  final HttpServer server;
  final String mode;
  final List<Map<String, dynamic>> requests = [];
  String? error;
  FixtureServer._(this.server, this.mode);

  static Future<FixtureServer> start({String mode = 'normal'}) async {
    final fixture = FixtureServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      mode,
    );
    fixture.server.listen((request) => fixture._serve(request));
    return fixture;
  }

  String get endpoint => 'http://127.0.0.1:${server.port}';
  Future<void> close() => server.close(force: true);

  Future<void> _serve(HttpRequest request) async {
    try {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      requests.add(body);
      if (mode == 'http_error') {
        request.response.statusCode = 503;
        request.response.write('{"error":{"message":"fixture unavailable"}}');
        await request.response.close();
        return;
      }
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      request.response.bufferOutput = false;
      if (mode == 'stall') {
        request.response.write(': fixture waiting\n\n');
        await request.response.flush();
        return; // Only explicit cancellation should finish this run.
      }
      final messages = body['messages'] as List;
      if (requests.length > 1) {
        final previous = requests[requests.length - 2];
        if (jsonEncode(body['tools']) != jsonEncode(previous['tools']))
          throw StateError('Tool definitions changed');
        final prior = previous['messages'] as List;
        if (jsonEncode(messages.take(prior.length).toList()) !=
            jsonEncode(prior))
          throw StateError('History prefix changed');
      }
      final round = requests.length;
      final chunks = <Map<String, dynamic>>[];
      if (round <= 2) {
        final tool = round == 1 ? 'write' : 'read';
        final args = mode == 'malformed'
            ? '{bad-json'
            : jsonEncode({
                'name': 'agent-roundtrip.txt',
                if (round == 1) 'text': 'Crux Agent SDK tool roundtrip',
              });
        final cut = args.length ~/ 2;
        chunks.add({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'fixture-$round',
                    'type': 'function',
                    'function': {
                      'name': tool,
                      'arguments': args.substring(0, cut),
                    },
                  },
                ],
              },
              'finish_reason': null,
            },
          ],
        });
        chunks.add({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'function': {'arguments': args.substring(cut)},
                  },
                ],
              },
              'finish_reason': null,
            },
          ],
        });
        chunks.add({
          'choices': [
            {'delta': {}, 'finish_reason': 'tool_calls'},
          ],
        });
      } else {
        final tools = messages.where((m) => m['role'] == 'tool').toList();
        if (tools.length != 2)
          throw StateError('Expected two paired tool results');
        final read = jsonDecode(tools.last['content'] as String) as Map;
        if (mode == 'normal' && read['text'] != 'Crux Agent SDK tool roundtrip')
          throw StateError('Read result mismatch');
        chunks.add({
          'choices': [
            {
              'delta': {
                'content': mode == 'normal'
                    ? 'Tool roundtrip completed.'
                    : '无效参数未执行。',
              },
              'finish_reason': null,
            },
          ],
        });
        chunks.add({
          'choices': [
            {'delta': {}, 'finish_reason': 'stop'},
          ],
        });
      }
      for (final chunk in chunks) {
        // Split a UTF-8 SSE frame at arbitrary byte boundaries to validate
        // the transport decoder, not just pre-parsed fake LlmChunk objects.
        final bytes = utf8.encode('data: ${jsonEncode(chunk)}\n\n');
        for (var i = 0; i < bytes.length; i += 7) {
          request.response.add(
            bytes.sublist(i, (i + 7).clamp(0, bytes.length)),
          );
          await request.response.flush();
        }
      }
      request.response.write('data: [DONE]\n\n');
      await request.response.close();
    } catch (e) {
      error = '$e';
      try {
        await request.response.close();
      } catch (_) {}
    }
  }
}
