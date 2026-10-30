import 'dart:convert';

import 'package:dsh_pet_flutter/core/config/ai_config.dart';
import 'package:dsh_pet_flutter/core/result.dart';
import 'package:dsh_pet_flutter/features/ai/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('OpenAI 兼容请求构造与回复解析', () async {
    late http.Request captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '主人好呀'},
              },
            ],
          }),
        ),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final service = AiService(
      config: const AiConfig(
        provider: 'openai',
        baseUrl: 'https://example.test/v1',
        model: 'test-model',
      ),
      keyLoader: () async => 'sk-test',
      client: client,
    );

    final result = await service.chat(
      messages: const [AiMessage.user('你好')],
      system: '你是桌宠',
    );
    expect(result, isA<Success<String>>());
    expect((result as Success<String>).value, '主人好呀');
    expect(captured.url.toString(), 'https://example.test/v1/chat/completions');
    expect(captured.headers['Authorization'], 'Bearer sk-test');
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['model'], 'test-model');
    final messages = body['messages'] as List;
    expect(messages.first['role'], 'system');
    expect(messages.last['content'], '你好');
  });

  test('OpenAI 缺少 key 时明确失败而不是发请求', () async {
    var called = false;
    final service = AiService(
      config: const AiConfig(provider: 'openai'),
      keyLoader: () async => '',
      client: MockClient((request) async {
        called = true;
        return http.Response('{}', 200);
      }),
    );
    final result = await service.chat(messages: const [AiMessage.user('你好')]);
    expect(result, isA<Failure<String>>());
    expect((result as Failure<String>).code, 'ai.no-key');
    expect(called, isFalse);
  });

  test('HTTP 错误返回结构化原因', () async {
    final service = AiService(
      config: const AiConfig(provider: 'openai'),
      keyLoader: () async => 'k',
      client: MockClient((request) async => http.Response('bad key', 401)),
    );
    final result = await service.chat(messages: const [AiMessage.user('你好')]);
    expect(result, isA<Failure<String>>());
    final failure = result as Failure<String>;
    expect(failure.code, 'ai.http-401');
    expect(failure.reason, contains('bad key'));
  });

  test('Ollama 请求与回复解析', () async {
    late http.Request captured;
    final service = AiService(
      config: const AiConfig(
        provider: 'ollama',
        baseUrl: 'http://127.0.0.1:11434/',
        model: 'qwen2.5',
      ),
      keyLoader: () async => '',
      client: MockClient((request) async {
        captured = request;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'message': {'content': '本地模型回复'},
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final result = await service.chat(messages: const [AiMessage.user('你好')]);
    expect((result as Success<String>).value, '本地模型回复');
    expect(captured.url.toString(), 'http://127.0.0.1:11434/api/chat');
  });

  test('未启用时直接返回配置原因', () async {
    final service = AiService(
      config: const AiConfig(),
      keyLoader: () async => 'k',
    );
    final result = await service.chat(messages: const [AiMessage.user('你好')]);
    expect(result, isA<Failure<String>>());
    expect((result as Failure<String>).code, 'ai.disabled');
    service.dispose();
  });
}
