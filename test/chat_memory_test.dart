import 'dart:io';

import 'package:dsh_pet_flutter/core/paths/app_paths.dart';
import 'package:dsh_pet_flutter/features/ai/chat_memory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('dsh_pet_memory_test_');
    AppPaths.overrideRoot(temp);
  });
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('对话记忆落盘并在新实例中恢复，上下文按轮数截断', () {
    final memory = ChatMemory();
    memory.appendRound('第一问', '第一答');
    memory.appendRound('第二问', '第二答');
    memory.appendRound('第三问', '第三答');

    final restored = ChatMemory();
    expect(restored.messages.length, 6);
    expect(restored.messages.first.content, '第一问');
    expect(restored.messages.last.content, '第三答');

    final context = restored.context(2);
    expect(context.length, 4);
    expect(context.first.content, '第二问');
    expect(context.last.content, '第三答');
  });

  test('清空会同步写回磁盘', () {
    final memory = ChatMemory()..appendRound('问', '答');
    memory.clear();
    expect(ChatMemory().messages, isEmpty);
  });

  test('超过原文上限时只保留最近的消息，磁盘不会无限增长', () {
    final memory = ChatMemory();
    for (var index = 0; index < chatMemoryMaxMessages / 2 + 20; index++) {
      memory.appendRound('问$index', '答$index');
    }
    expect(memory.messages.length, chatMemoryMaxMessages);
    expect(ChatMemory().messages.length, chatMemoryMaxMessages);
    expect(memory.messages.first.content, contains('问20'));
  });

  test('装配摘要器后：裁剪丢弃的原文折叠进滚动摘要并持久化', () async {
    final memory = ChatMemory();
    memory.summarizer = (dropped, current) async =>
        '$current｜丢弃${dropped.length}条（含${dropped.first.content}）';
    for (var index = 0; index < chatMemoryMaxMessages ~/ 2 + 2; index++) {
      memory.appendRound('问$index', '答$index');
    }
    // 摘要是异步的：等在飞调用与排队批次全部落地。
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(memory.rollingSummary, contains('丢弃'));
    // 新实例（重启路径）必须读回同一段摘要。
    expect(ChatMemory().rollingSummary, memory.rollingSummary);
  });

  test('摘要器失败返回 null：保留旧摘要，等价回退纯丢弃现状', () async {
    final memory = ChatMemory();
    memory.summarizer = (dropped, current) async => null;
    for (var index = 0; index < chatMemoryMaxMessages ~/ 2 + 2; index++) {
      memory.appendRound('问$index', '答$index');
    }
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(memory.rollingSummary, isEmpty);
    expect(memory.messages.length, chatMemoryMaxMessages);
  });

  test('摘要超长被截断保底；clear 连摘要一起清', () async {
    final memory = ChatMemory();
    memory.summarizer = (dropped, current) async => '长' * 800;
    for (var index = 0; index < chatMemoryMaxMessages ~/ 2 + 2; index++) {
      memory.appendRound('问$index', '答$index');
    }
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    // 600 字 + 省略号 = 601，防止摘要无限膨胀挤爆上下文。
    expect(memory.rollingSummary.length, 601);

    memory.clear();
    expect(memory.rollingSummary, isEmpty);
    expect(ChatMemory().rollingSummary, isEmpty);
  });
}
