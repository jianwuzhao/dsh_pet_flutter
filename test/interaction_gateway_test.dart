import 'package:dsh_pet_flutter/ai/llm_provider.dart';
import 'package:dsh_pet_flutter/ai/llm_router.dart';
import 'package:dsh_pet_flutter/core/config/app_config.dart';
import 'package:dsh_pet_flutter/core/result.dart';
import 'package:dsh_pet_flutter/features/linkage/assistant_adapters.dart';
import 'package:dsh_pet_flutter/features/linkage/dispatcher.dart';
import 'package:dsh_pet_flutter/gateway/interaction_gateway.dart';
import 'package:dsh_pet_flutter/platform/pet_platform.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可控回复的假提供者。
class FakeProvider extends LlmProvider {
  FakeProvider(
    this.providerId, {
    this.ready = true,
    this.replyCapable = true,
    this.chatResult,
  });

  final String providerId;
  final bool ready;
  final bool replyCapable;
  final Result<LlmReply>? chatResult;

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
      chatResult ?? Success(LlmReply(content: '$providerId 回复'));
}

/// 行为可注入的假适配器：让 Dispatcher 的转发路径可控可断言。
class FakeAdapter extends AssistantAdapter {
  FakeAdapter(String id, this.behavior)
    : super(
        AdapterConfig(
          id: id,
          displayName: id,
          appName: '',
          bundleId: '',
          uriTemplate: '',
          delivery: DeliveryMode.clipboard,
        ),
        PetPlatform(),
      );

  final Future<DispatchOutcome> Function(String prompt) behavior;

  @override
  Future<DispatchOutcome> dispatch(String prompt) => behavior(prompt);
}

Dispatcher dispatcherWith(FakeAdapter adapter) =>
    Dispatcher(registry: AdapterRegistry({adapter.id: adapter}), activeId: adapter.id);

void main() {
  group('submit 统一入口', () {
    test('未接会话服务时维持转发行为，返回投递结果', () async {
      final dispatcher = dispatcherWith(
        FakeAdapter('trae-cn', (prompt) async {
          return const DispatchOutcome(ok: true);
        }),
      );
      final gateway = InteractionGateway(
        dispatcher: dispatcher,
        router: LlmRouter(providers: [], activeId: 'none'),
      );

      final result = await gateway.submit('帮我看看', InputSource.panel);

      expect(result, isA<Success<DispatchOutcome>>());
      expect((result as Success<DispatchOutcome>).value.ok, isTrue);
    });

    test('接入会话服务后输入走对话路径并带回回复', () async {
      final gateway = InteractionGateway(
        dispatcher: dispatcherWith(
          FakeAdapter('trae-cn', (prompt) async => const DispatchOutcome(ok: true)),
        ),
        router: LlmRouter(providers: [], activeId: 'none'),
        conversation: (prompt) async =>
            Success(LlmReply(content: '收到：$prompt', sentiment: 'positive')),
      );

      final result = await gateway.submit('在吗', InputSource.eventServer);

      final outcome = (result as Success<DispatchOutcome>).value;
      expect(outcome.ok, isTrue);
      expect(outcome.reply, '收到：在吗');
    });

    test('空文本不外发，直接结构化失败', () async {
      final gateway = InteractionGateway(
        dispatcher: dispatcherWith(
          FakeAdapter('trae-cn', (prompt) async => const DispatchOutcome(ok: true)),
        ),
        router: LlmRouter(providers: [], activeId: 'none'),
      );

      final result = await gateway.submit('   ', InputSource.panel);

      expect((result as Failure<DispatchOutcome>).code, 'dispatch.empty');
    });
  });

  group('chat 对话端点', () {
    test('能回复的提供者返回回复内容', () async {
      final gateway = InteractionGateway(
        dispatcher: dispatcherWith(
          FakeAdapter('trae-cn', (prompt) async => const DispatchOutcome(ok: true)),
        ),
        router: LlmRouter(
          providers: [FakeProvider('openai')],
          activeId: 'openai',
        ),
      );

      final reply = await gateway.chat('你好');

      expect(reply.ok, isTrue);
      expect(reply.reply, 'openai 回复');
      expect(reply.degraded, isFalse);
    });

    test('降级时附上气泡说明', () async {
      final gateway = InteractionGateway(
        dispatcher: dispatcherWith(
          FakeAdapter('trae-cn', (prompt) async => const DispatchOutcome(ok: true)),
        ),
        router: LlmRouter(
          providers: [FakeProvider('openai', ready: false), FakeProvider('ollama')],
          activeId: 'openai',
        ),
      );

      final reply = await gateway.chat('你好');

      expect(reply.ok, isTrue);
      expect(reply.degraded, isTrue);
      expect(reply.reason, contains('降级'));
    });

    test('只剩转发能力（trae 桥）时给出明确原因，不伪造回复', () async {
      final bridge = FakeProvider('trae-bridge', replyCapable: false);
      final gateway = InteractionGateway(
        dispatcher: dispatcherWith(
          FakeAdapter('trae-cn', (prompt) async => const DispatchOutcome(ok: true)),
        ),
        router: LlmRouter(providers: [bridge], activeId: 'trae-bridge'),
      );

      final reply = await gateway.chat('你好');

      expect(reply.ok, isFalse);
      expect(reply.reason, contains('转发'));
    });

    test('没有任何可用提供者时提示去设置', () async {
      final gateway = InteractionGateway(
        dispatcher: dispatcherWith(
          FakeAdapter('trae-cn', (prompt) async => const DispatchOutcome(ok: true)),
        ),
        router: LlmRouter(providers: [FakeProvider('openai', ready: false)], activeId: 'openai'),
      );

      final reply = await gateway.chat('你好');

      expect(reply.ok, isFalse);
      expect(reply.reason, contains('设置'));
    });

    test('提供者请求失败时带回原因码', () async {
      final gateway = InteractionGateway(
        dispatcher: dispatcherWith(
          FakeAdapter('trae-cn', (prompt) async => const DispatchOutcome(ok: true)),
        ),
        router: LlmRouter(
          providers: [
            FakeProvider(
              'openai',
              chatResult: const Failure('ai.no-key', '缺少 API Key'),
            ),
          ],
          activeId: 'openai',
        ),
      );

      final reply = await gateway.chat('你好');

      expect(reply.ok, isFalse);
      expect(reply.reason, contains('ai.no-key'));
    });
  });
}
