import 'dart:io';

import 'package:dsh_pet_flutter/ai/conversation.dart';
import 'package:dsh_pet_flutter/ai/llm_provider.dart';
import 'package:dsh_pet_flutter/ai/llm_router.dart';
import 'package:dsh_pet_flutter/core/result.dart';
import 'package:dsh_pet_flutter/features/ai/chat_memory.dart';
import 'package:dsh_pet_flutter/gateway/privacy_center.dart';
import 'package:dsh_pet_flutter/persona/emotion/emotion_state.dart';
import 'package:dsh_pet_flutter/persona/memory/memory_entry.dart';
import 'package:dsh_pet_flutter/persona/memory/memory_store.dart';
import 'package:dsh_pet_flutter/persona/persona_dna.dart';
import 'package:dsh_pet_flutter/persona/profile_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可编程假提供者：记录收到的请求，按脚本回话。
class FakeProvider extends LlmProvider {
  FakeProvider({this.ready = true, this.script});

  final bool ready;
  final List<LlmRequest> requests = [];
  String? script;

  @override
  String get id => 'fake';
  @override
  String get displayName => '假提供者';
  @override
  bool get supportsReply => true;
  @override
  Future<bool> get isReady async => ready;

  @override
  Future<Result<LlmReply>> chat(LlmRequest request) async {
    requests.add(request);
    final text = script;
    if (text == null) {
      return const Failure('ai.error', '提供者炸了');
    }
    return Success(LlmReply.parse(text));
  }
}

void main() {
  late Directory tmpDir;
  late MemoryStore memory;
  late PrivacyCenter privacy;
  late ChatMemory history;
  late FakeProvider provider;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('conversation_test');
    memory = MemoryStore(directory: tmpDir);
    privacy = PrivacyCenter(directory: tmpDir);
    privacy.load();
    history = ChatMemory(
      file: File('${tmpDir.path}/history.json'),
    );
    provider = FakeProvider();
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  ConversationService buildService({int rounds = 8, String? policyHint}) =>
      ConversationService(
        routerLoader: () => LlmRouter(providers: [provider], activeId: 'fake'),
        memory: memory,
        privacy: privacy,
        history: history,
        dnaLoader: () => const PersonaDna(name: '小蓝', address: '老板'),
        emotionLoader: () => const EmotionView(
          valence: 0.5,
          arousal: 0.5,
          intimacy: 0.8,
        ),
        policyHintLoader: policyHint == null ? null : () => policyHint,
        rounds: rounds,
      );

  test('上下文组装：DNA/情绪/记忆/底线/协议都进 system', () async {
    memory.add(MemoryEntry(
      id: 'm1',
      kind: MemoryKind.preference,
      content: '称呼偏好：老板',
      createdAt: DateTime(2026, 1, 1, 12),
    ));

    provider.script = '[[sentiment:positive]]\n好的，老板。';
    final service = buildService();
    final result = await service.handle('在吗');

    expect(result, isA<Success<LlmReply>>());
    final system = provider.requests.single.system;
    expect(system, contains('小蓝'));
    expect(system, contains('老板'));
    expect(system, contains('称呼偏好：老板'));
    expect(system, contains('开心'));
    expect(system, contains('亲昵、可以开玩笑'));
    expect(system, contains('不操纵用户'));
    expect(system, contains('[[sentiment:'));
    expect(system, contains('[[memory:'));
    expect(provider.requests.single.messages.single.content, '在吗');
  });

  test('回复剥掉 memory 标记：正文干净 + pending 入库', () async {
    provider.script =
        '[[sentiment:positive]]\n收到。[[memory:fact|在写 Flutter 项目]]';
    final service = buildService();
    final result = await service.handle('我今天在写 Flutter');

    expect((result as Success<LlmReply>).value.content, '收到。');
    final pending = memory.pending;
    expect(pending.length, 1);
    expect(pending.single.content, '在写 Flutter 项目');
    expect(pending.single.status, MemoryStatus.pending);
  });

  test('策略参数作为表达偏好注入 system；安全边界仍以人格底线为准', () async {
    provider.script = '[[sentiment:neutral]]\n好。';
    final service = buildService(policyHint: '回复尽量短（一到两句）；不使用表情符号。');
    await service.handle('在吗');

    final system = provider.requests.single.system;
    expect(system, contains('表达偏好（用户反馈习得）'));
    expect(system, contains('回复尽量短'));
    // 策略只能调整表达偏好，硬性底线段落始终存在。
    expect(system, contains('硬性底线（任何时候不可违背）'));
    expect(system, contains('不操纵用户'));
  });

  test('用户文本的规则模式直写 active（“以后叫我老板”）', () async {
    provider.script = '[[sentiment:positive]]\n好的。';
    final service = buildService();
    await service.handle('以后叫我老板');

    final active = memory.entries(status: MemoryStatus.active);
    expect(active.map((e) => e.content), contains('称呼偏好：老板'));
  });

  test('memoryRecording 关闭时不写任何记忆（规则与候选都不写）', () async {
    privacy.update(const PrivacySettings(memoryRecording: false));
    provider.script = '[[sentiment:positive]]\n好。[[memory:fact|某事实]]';
    final service = buildService();
    await service.handle('以后叫我老板');

    expect(memory.entries(), isEmpty);
  });

  test('历史轮次注入与截断', () async {
    provider.script = '[[sentiment:neutral]]\n嗯。';
    final service = buildService(rounds: 2);
    // 预置 5 轮历史。
    for (var i = 0; i < 5; i++) {
      history.appendRound('问题$i', '回答$i');
    }
    await service.handle('新问题');

    final messages = provider.requests.single.messages;
    expect(messages.length, 5); // 2 轮历史 = 4 条 + 新输入 1 条。
    expect(messages.first.content, '问题3');
    expect(messages.last.content, '新问题');
  });

  test('成功后历史落盘一轮（剥标记后的正文）', () async {
    provider.script = '[[sentiment:positive]]\n正文。[[memory:fact|x]]';
    final service = buildService();
    await service.handle('问题');

    expect(history.messages.length, 2);
    expect(history.messages.last.content, '正文。');
  });

  test('提供者失败透传；无可用提供者给明确原因', () async {
    final service = buildService();
    final failed = await service.handle('在吗');
    expect(failed, isA<Failure<LlmReply>>());
    expect((failed as Failure<LlmReply>).code, 'ai.error');

    final offline = ConversationService(
      routerLoader: () => LlmRouter(providers: const [], activeId: 'none'),
      memory: memory,
      privacy: privacy,
    );
    final noProvider = await offline.handle('在吗');
    expect(noProvider, isA<Failure<LlmReply>>());
    expect((noProvider as Failure<LlmReply>).code, 'ai.unavailable');
  });
}
