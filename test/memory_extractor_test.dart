import 'package:dsh_pet_flutter/persona/memory/memory_entry.dart';
import 'package:dsh_pet_flutter/persona/memory/memory_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const extractor = MemoryExtractor();
  final now = DateTime(2026, 1, 1, 12);

  group('规则抽取：称呼', () {
    test('“以后叫我老板” → 偏好记忆', () {
      final entries = extractor.extractRules('以后叫我老板，别叫主人了', now: now);
      expect(entries.length, 1); // “别叫主人”不是回避规则（别提/别聊），不误收。
      expect(entries.first.content, '称呼偏好：老板');
    });

    test('带语气词与引号也能抽出干净称呼', () {
      final entries = extractor.extractRules('都叫我“老李”吧', now: now);
      expect(entries, isNotEmpty);
      expect(entries.first.content, '称呼偏好：老李');
    });

    test('没有意愿语境不抽取（防“叫我妈买菜”误判）', () {
      expect(extractor.extractRules('叫我妈买菜', now: now), isEmpty);
      expect(extractor.extractRules('他叫我小王', now: now), isEmpty);
    });
  });

  group('规则抽取：回避话题', () {
    test('“别提前女友” → 回避话题', () {
      final entries = extractor.extractRules('别提前女友，过去的事就过去了', now: now);
      expect(entries.map((e) => e.content), contains('回避话题：前女友'));
    });

    test('“不想聊工作” → 回避话题', () {
      final entries = extractor.extractRules('今天不想聊工作了', now: now);
      expect(
        entries.map((e) => e.content),
        contains(contains('回避话题：工作')),
      );
    });

    test('一句话多个回避都收下', () {
      final entries = extractor.extractRules(
        '别提股票，也不要聊加班的事',
        now: now,
      );
      expect(entries.where((e) => e.content.startsWith('回避话题')).length, 2);
    });
  });

  group('规则抽取：作息', () {
    test('“我一般 1 点半睡” → 事实记忆', () {
      final entries = extractor.extractRules('我一般1点半才睡', now: now);
      expect(entries.map((e) => e.content), contains('作息：约 1 点半睡'));
    });

    test('“每天 8 点起床” → 事实记忆', () {
      final entries = extractor.extractRules('我每天8点起床', now: now);
      expect(entries.map((e) => e.content), contains('作息：约 8 点起床'));
    });

    test('无显式时间不猜', () {
      expect(extractor.extractRules('我睡得很晚', now: now), isEmpty);
    });
  });

  group('LLM 标记解析', () {
    test('剥掉标记并生成 pending 候选', () {
      final (candidates, content) = extractor.extractFromReply(
        '好的老板！[[memory:preference|称呼偏好：老板]]\n有什么想聊的尽管说。',
        now: now,
      );
      expect(candidates.length, 1);
      expect(candidates.single.kind, MemoryKind.preference);
      expect(candidates.single.status, MemoryStatus.pending);
      expect(candidates.single.source, 'llm');
      expect(candidates.single.content, '称呼偏好：老板');
      expect(content, '好的老板！\n有什么想聊的尽管说。');
    });

    test('多个标记全部收集；未知 kind 丢弃但不丢正文', () {
      final (candidates, content) = extractor.extractFromReply(
        '记下了。[[memory:fact|在写 Flutter 项目]][[memory:tag|未知类型]]',
        now: now,
      );
      expect(candidates.length, 1);
      expect(candidates.single.kind, MemoryKind.fact);
      expect(content, '记下了。');
    });

    test('无标记正文原样返回', () {
      final (candidates, content) = extractor.extractFromReply(
        '普通回复，没有任何标记。',
        now: now,
      );
      expect(candidates, isEmpty);
      expect(content, '普通回复，没有任何标记。');
    });
  });

  group('抽取条目的元数据', () {
    test('规则条目 active + scope chat；同批多条 id 不重复', () {
      final entries = extractor.extractRules(
        '以后叫我老板，别提股票，我1点睡',
        now: now,
      );
      expect(entries, isNotEmpty);
      expect(entries.every((e) => e.status == MemoryStatus.active), isTrue);
      expect(entries.every((e) => e.scope == memoryScopeChat), isTrue);
      expect(entries.map((e) => e.id).toSet().length, entries.length);
    });
  });
}
