import 'package:dsh_pet_flutter/ai/llm_provider.dart';
import 'package:dsh_pet_flutter/ai/llm_router.dart';
import 'package:dsh_pet_flutter/ai/providers/ollama_provider.dart';
import 'package:dsh_pet_flutter/ai/providers/openai_provider.dart';
import 'package:dsh_pet_flutter/ai/providers/trae_bridge_provider.dart';
import 'package:dsh_pet_flutter/ai/tool_registry.dart';
import 'package:dsh_pet_flutter/core/result.dart';
import 'package:dsh_pet_flutter/features/linkage/assistant_adapters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 可控就绪状态的假提供者。
class FakeProvider extends LlmProvider {
  FakeProvider(this.providerId, {this.ready = true, this.replyCapable = true});

  final String providerId;
  final bool ready;
  final bool replyCapable;

  @override
  String get id => providerId;
  @override
  String get displayName => providerId;
  @override
  bool get supportsReply => replyCapable;
  @override
  Future<bool> get isReady async => ready;
  @override
  Future<Result<LlmReply>> chat(LlmRequest request) async =>
      Success(LlmReply(content: '$providerId 回复'));
}

void main() {
  TraeBridgeProvider bridge() => TraeBridgeProvider(
    send: (_) async => const Success(DispatchOutcome.success),
  );

  group('LlmRouter 降级链', () {
    test('active 可用则直选，不降级', () async {
      final router = LlmRouter(
        providers: [FakeProvider('openai'), bridge()],
        activeId: 'openai',
      );
      final resolution = await router.resolve();
      expect(resolution!.provider.id, 'openai');
      expect(resolution.degraded, isFalse);
      expect(resolution.notice, isNull);
    });

    test('active 不可用按 openai→ollama→trae-bridge 降级并给出气泡说明', () async {
      final router = LlmRouter(
        providers: [
          FakeProvider('openai', ready: false),
          FakeProvider('ollama'),
          bridge(),
        ],
        activeId: 'openai',
      );
      final resolution = await router.resolve();
      expect(resolution!.provider.id, 'ollama');
      expect(resolution.degraded, isTrue);
      expect(resolution.notice, contains('降级'));
    });

    test('provider=none 视为未指定，直接走兜底链', () async {
      final router = LlmRouter(
        providers: [FakeProvider('openai', ready: false), bridge()],
        activeId: 'none',
      );
      final resolution = await router.resolve();
      expect(resolution!.provider.id, 'trae-bridge');
      expect(resolution.notice, contains('未指定'));
    });

    test('全部不可用返回 null（装配漏了桥，属接线错误）', () async {
      final router = LlmRouter(
        providers: [FakeProvider('openai', ready: false)],
        activeId: 'openai',
      );
      expect(await router.resolve(), isNull);
    });

    test('配置了不存在的 provider 也走降级链', () async {
      final router = LlmRouter(providers: [bridge()], activeId: 'nonexistent');
      final resolution = await router.resolve();
      expect(resolution!.provider.id, 'trae-bridge');
      expect(resolution.degraded, isTrue);
    });

    test('provider=none 且 Ollama 不可达：快速落到转发桥，不在不可达后端上白等', () async {
      final stopwatch = Stopwatch()..start();
      final router = LlmRouter(
        providers: [
          OpenAiProvider(
            baseUrl: 'https://api.openai.com/v1',
            model: 'gpt-4o-mini',
            keyLoader: () async => '', // 没有 key → 不可用
            client: MockClient((_) async => http.Response('{}', 200)),
          ),
          OllamaProvider(
            // 典型事故：OpenAI 的地址被当成 Ollama 打。
            baseUrl: 'https://api.openai.com/v1',
            model: 'gpt-4o-mini',
            probeTimeout: const Duration(milliseconds: 80),
            client: MockClient((_) async => http.Response('not found', 404)),
          ),
          bridge(),
        ],
        activeId: 'none',
      );

      final resolution = await router.resolve();
      expect(resolution!.provider.id, 'trae-bridge');
      expect(resolution.provider.supportsReply, isFalse);
      expect(stopwatch.elapsedMilliseconds, lessThan(1000));
    });
  });

  group('ToolRegistry 门禁', () {
    test('未授权时拒绝执行，不静默降级', () async {
      final registry = ToolRegistry()
        ..register(MemoryProposalTool((content, kind) async => Success('提案:$kind:$content')));

      final denied = await registry.run(
        'memory_propose',
        {'content': '叫我老板', 'kind': 'preference'},
        gate: (_) async => false,
      );
      expect((denied as Failure<String>).code, 'tool.denied');
    });

    test('授权后委托注入的回调执行', () async {
      final registry = ToolRegistry()
        ..register(
          MemoryProposalTool((content, kind) async => Success('提案:$kind:$content')),
        )
        ..register(OpenAppTool((appId, prompt) async => Success('已唤起:$appId')));

      final allowed = await registry.run(
        'memory_propose',
        {'content': '叫我老板', 'kind': 'preference'},
        gate: (capability) async => capability == 'memoryRecording',
      );
      expect((allowed as Success<String>).value, '提案:preference:叫我老板');

      final opened = await registry.run(
        'open_app',
        {'appId': 'trae-cn', 'prompt': '看看这个'},
        gate: (_) async => false, // 唤起软件不涉隐私，门禁不该拦
      );
      expect((opened as Success<String>).value, '已唤起:trae-cn');
    });

    test('参数缺失与未注册工具都结构化失败', () async {
      final registry = ToolRegistry()
        ..register(OpenAppTool((appId, prompt) async => Success('ok')));

      final missingArgs = await registry.run(
        'open_app',
        {},
        gate: (_) async => true,
      );
      expect((missingArgs as Failure<String>).code, 'tool.args');

      final unknown = await registry.run(
        'nope',
        {},
        gate: (_) async => true,
      );
      expect((unknown as Failure<String>).code, 'tool.unknown');
    });
  });
}
