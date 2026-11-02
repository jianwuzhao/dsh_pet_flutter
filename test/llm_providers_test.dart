import 'dart:convert';

import 'package:dsh_pet_flutter/ai/llm_provider.dart';
import 'package:dsh_pet_flutter/ai/providers/ollama_provider.dart';
import 'package:dsh_pet_flutter/ai/providers/openai_provider.dart';
import 'package:dsh_pet_flutter/ai/providers/trae_bridge_provider.dart';
import 'package:dsh_pet_flutter/core/result.dart';
import 'package:dsh_pet_flutter/features/linkage/assistant_adapters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

/// 记录 close 的外部客户端：验证 provider 只关自己建的 client。
class _TrackingClient extends http.BaseClient {
  _TrackingClient({required this.onClose});

  final void Function() onClose;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(Stream.value(utf8.encode('{}')), 200);

  @override
  void close() => onClose();
}

void main() {
  group('OpenAiProvider', () {
    test('请求带 Bearer key，system 排最前，回复解析并剥情绪标记', () async {
      late http.Request captured;
      final provider = OpenAiProvider(
        baseUrl: 'https://api.example.com/v1/',
        model: 'gpt-test',
        keyLoader: () async => 'sk-test',
        client: MockClient((request) async {
          captured = request;
          return _json({
            'choices': [
              {
                'message': {
                  'content': '[[sentiment:positive]]\n搞定啦',
                },
              },
            ],
          });
        }),
      );

      final reply = await provider.chat(
        LlmRequest(
          system: '你是桌宠',
          messages: const [LlmMessage.user('你好')],
        ),
      );

      expect(captured.url.toString(), 'https://api.example.com/v1/chat/completions');
      expect(captured.headers['Authorization'], 'Bearer sk-test');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      final messages = body['messages'] as List;
      expect((messages.first as Map)['role'], 'system');
      expect((messages.last as Map)['content'], '你好');

      final value = (reply as Success<LlmReply>).value;
      expect(value.content, '搞定啦');
      expect(value.sentiment, 'positive');
    });

    test('缺 key 时不可用且 chat 结构化失败', () async {
      final provider = OpenAiProvider(
        baseUrl: 'https://api.example.com/v1',
        model: 'gpt-test',
        keyLoader: () async => '',
        client: MockClient((_) async => _json({})),
      );
      expect(await provider.isReady, isFalse);
      final reply = await provider.chat(
        const LlmRequest(messages: [LlmMessage.user('hi')]),
      );
      expect((reply as Failure<LlmReply>).code, 'ai.no-key');
    });

    test('HTTP 4xx 与空回复都返回失败', () async {
      final provider = OpenAiProvider(
        baseUrl: 'https://api.example.com/v1',
        model: 'gpt-test',
        keyLoader: () async => 'sk-test',
        client: MockClient((_) async => _json({'error': 'boom'}, status: 401)),
      );
      final reply = await provider.chat(
        const LlmRequest(messages: [LlmMessage.user('hi')]),
      );
      expect((reply as Failure<LlmReply>).code, 'ai.http-401');
    });

    test('2xx 但响应体非 JSON 时返回结构化失败，不让 FormatException 逃出', () async {
      final provider = OpenAiProvider(
        baseUrl: 'https://api.example.com/v1',
        model: 'gpt-test',
        keyLoader: () async => 'sk-test',
        // 典型场景：网关/代理返回 HTML 错误页但状态码 200。
        client: MockClient((_) async => http.Response('<html>oops</html>', 200)),
      );
      final reply = await provider.chat(
        const LlmRequest(messages: [LlmMessage.user('hi')]),
      );
      expect((reply as Failure<LlmReply>).code, 'ai.malformed');
      expect(reply.reason, contains('无法解析'));
    });

    test('2xx 但 JSON 顶层不是对象时同样结构化失败', () async {
      final provider = OpenAiProvider(
        baseUrl: 'https://api.example.com/v1',
        model: 'gpt-test',
        keyLoader: () async => 'sk-test',
        client: MockClient((_) async => http.Response('[1,2,3]', 200)),
      );
      final reply = await provider.chat(
        const LlmRequest(messages: [LlmMessage.user('hi')]),
      );
      expect((reply as Failure<LlmReply>).code, 'ai.malformed');
    });

    test('走抽象接口即可释放资源；外部传入的 client 不被夺走关闭', () {
      var externalClosed = false;
      // 显式以抽象类型持有，模拟网关/内核的持有方式。
      final LlmProvider provider = OpenAiProvider(
        baseUrl: 'https://api.example.com/v1',
        model: 'gpt-test',
        keyLoader: () async => 'sk-test',
        client: _TrackingClient(onClose: () => externalClosed = true),
      );

      // dispose 在接口上可用（编译通过即证明），且不崩溃。
      provider.dispose();
      expect(externalClosed, isFalse);
    });
  });

  group('OllamaProvider', () {
    test('请求打到 /api/chat 且 stream=false，解析 message.content', () async {
      late http.Request captured;
      final provider = OllamaProvider(
        baseUrl: 'http://127.0.0.1:11434',
        model: 'qwen-test',
        client: MockClient((request) async {
          captured = request;
          return _json({'message': {'content': '本地回复'}});
        }),
      );

      final reply = await provider.chat(
        const LlmRequest(messages: [LlmMessage.user('你好')]),
      );

      expect(captured.url.toString(), 'http://127.0.0.1:11434/api/chat');
      expect((jsonDecode(captured.body) as Map)['stream'], false);
      expect((reply as Success<LlmReply>).value.content, '本地回复');
      expect(provider.supportsReply, isTrue);
    });

    test('空回复返回失败', () async {
      final provider = OllamaProvider(
        baseUrl: 'http://127.0.0.1:11434',
        model: 'qwen-test',
        client: MockClient((_) async => _json({'message': {'content': ''}})),
      );
      final reply = await provider.chat(
        const LlmRequest(messages: [LlmMessage.user('hi')]),
      );
      expect((reply as Failure<LlmReply>).code, 'ai.empty');
    });

    test('2xx 但响应体非 JSON 时返回结构化失败，不让 FormatException 逃出', () async {
      final provider = OllamaProvider(
        baseUrl: 'http://127.0.0.1:11434',
        model: 'qwen-test',
        client: MockClient((_) async => http.Response('not-json', 200)),
      );
      final reply = await provider.chat(
        const LlmRequest(messages: [LlmMessage.user('hi')]),
      );
      expect((reply as Failure<LlmReply>).code, 'ai.malformed');
    });

    test('2xx 但 JSON 顶层不是对象时返回结构化失败', () async {
      final provider = OllamaProvider(
        baseUrl: 'http://127.0.0.1:11434',
        model: 'qwen-test',
        client: MockClient((_) async => http.Response('[1,2]', 200)),
      );
      final reply = await provider.chat(
        const LlmRequest(messages: [LlmMessage.user('hi')]),
      );
      expect((reply as Failure<LlmReply>).code, 'ai.malformed');
    });
  });

  group('TraeBridgeProvider', () {
    test('supportsReply=false，chat 拒绝，send 委托回调', () async {
      var forwarded = '';
      final provider = TraeBridgeProvider(
        send: (prompt) async {
          forwarded = prompt;
          return const Success(DispatchOutcome.success);
        },
      );

      expect(provider.supportsReply, isFalse);
      expect(await provider.isReady, isTrue);

      final reply = await provider.chat(
        const LlmRequest(messages: [LlmMessage.user('hi')]),
      );
      expect((reply as Failure<LlmReply>).code, 'llm.no-reply');

      await provider.send('帮我看下这段代码');
      expect(forwarded, '帮我看下这段代码');
    });
  });

  group('LlmReply.parse 情绪标记协议', () {
    test('无标记时 sentiment 为空且保留原文', () {
      final reply = LlmReply.parse('  普通回复  ');
      expect(reply.content, '普通回复');
      expect(reply.sentiment, isNull);
    });

    test('标记后无正文也合法（正文为空串）', () {
      final reply = LlmReply.parse('[[sentiment:tired]]\n');
      expect(reply.sentiment, 'tired');
      expect(reply.content, '');
    });
  });
}
