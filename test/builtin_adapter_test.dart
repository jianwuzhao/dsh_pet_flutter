import 'dart:convert';
import 'dart:io';

import 'package:dsh_pet_flutter/core/config/ai_config.dart';
import 'package:dsh_pet_flutter/core/config/app_config.dart';
import 'package:dsh_pet_flutter/core/paths/app_paths.dart';
import 'package:dsh_pet_flutter/features/ai/chat_memory.dart';
import 'package:dsh_pet_flutter/features/ai/llm_client.dart';
import 'package:dsh_pet_flutter/features/linkage/assistant_adapters.dart';
import 'package:dsh_pet_flutter/platform/pet_platform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory temp;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('dsh_pet_builtin_test_');
    AppPaths.overrideRoot(temp);
  });
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('内置对话返回回复并写入记忆，下一轮带历史', () async {
    var calls = 0;
    late http.Request lastRequest;
    final service = AiService(
      config: const AiConfig(
        provider: 'openai',
        baseUrl: 'https://example.test/v1',
        model: 'test',
        memoryRounds: 2,
      ),
      keyLoader: () async => 'sk',
      client: MockClient((request) async {
        calls++;
        lastRequest = request;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '回复$calls'},
                },
              ],
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final memory = ChatMemory();
    final adapter = BuiltinAdapter(
      const AdapterConfig(
        id: 'builtin',
        displayName: '内置对话',
        appName: '',
        bundleId: '',
        uriTemplate: '',
        delivery: DeliveryMode.clipboard,
      ),
      PetPlatform(),
      ai: service,
      memory: memory,
      persona: '你是测试桌宠',
    );

    final first = await adapter.dispatch('你好');
    expect(first.ok, isTrue);
    expect(first.reply, '回复1');
    expect(memory.messages.length, 2);

    final second = await adapter.dispatch('第二句');
    expect(second.ok, isTrue);
    final body = jsonDecode(lastRequest.body) as Map<String, dynamic>;
    final messages = body['messages'] as List;
    // system + 第一轮两条 + 本轮 user
    expect(messages.length, 4);
    expect(messages.first['role'], 'system');
    expect(messages.last['content'], '第二句');
  });

  test('未配置 AI 时明确返回结构化失败', () async {
    final adapter = BuiltinAdapter(
      const AdapterConfig(
        id: 'builtin',
        displayName: '内置对话',
        appName: '',
        bundleId: '',
        uriTemplate: '',
        delivery: DeliveryMode.clipboard,
      ),
      PetPlatform(),
    );
    final result = await adapter.dispatch('你好');
    expect(result.ok, isFalse);
    expect(result.code, 'builtin.not-configured');
  });
}
