import 'dart:convert';
import 'dart:io';

import 'package:dsh_pet_flutter/core/result.dart';
import 'package:dsh_pet_flutter/persona/memory/memory_entry.dart';
import 'package:dsh_pet_flutter/persona/memory/memory_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmpDir;
  late MemoryStore store;

  MemoryEntry entry(
    MemoryKind kind,
    String content, {
    String scope = memoryScopeChat,
    DateTime? expireAt,
    MemoryStatus status = MemoryStatus.active,
    DateTime? createdAt,
  }) => MemoryEntry(
    id: 'id-${kind.name}-$content',
    kind: kind,
    content: content,
    scope: scope,
    expireAt: expireAt,
    createdAt: createdAt ?? DateTime(2026, 1, 1, 12),
    source: 'rule',
    status: status,
  );

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('memory_store_test');
    store = MemoryStore(directory: tmpDir);
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  group('MemoryStore CRUD', () {
    test('新增后按类读取，互不串扰', () {
      expect(
        store.add(entry(MemoryKind.preference, '称呼偏好：老板')),
        isA<Success<void>>(),
      );
      expect(
        store.add(entry(MemoryKind.fact, '作息：早八晚十二')),
        isA<Success<void>>(),
      );

      final all = store.entries();
      expect(all.length, 2);
      expect(
        store.entries(kind: MemoryKind.preference).single.content,
        '称呼偏好：老板',
      );
      expect(store.entries(kind: MemoryKind.fact).single.content, '作息：早八晚十二');
    });

    test('空内容与空 id 拒绝写入', () {
      expect(store.add(entry(MemoryKind.fact, '  ')), isA<Failure<void>>());
      expect(
        store.add(
          MemoryEntry(
            id: '',
            kind: MemoryKind.fact,
            content: '没有 id',
            createdAt: DateTime(2026, 1, 1, 12),
          ),
        ),
        isA<Failure<void>>(),
      );
    });

    test('纠正：按 id 替换内容并落盘', () {
      store.add(entry(MemoryKind.fact, '作息：早八'));
      final original = store.entries().single;

      final updated = original.copyWith(content: '作息：早八晚十二');
      expect(store.update(updated), isA<Success<void>>());
      expect(store.entries().single.content, '作息：早八晚十二');

      // 重开一个 store 验证确实写盘。
      final reopened = MemoryStore(directory: tmpDir);
      expect(reopened.entries().single.content, '作息：早八晚十二');
    });

    test('遗忘：单条删除与按类清空', () {
      store.add(entry(MemoryKind.episode, '一起调试到凌晨'));
      store.add(entry(MemoryKind.episode, '修好了内存泄漏'));

      expect(store.remove(store.entries().first.id), isA<Success<void>>());
      expect(store.entries().length, 1);

      expect(store.clearKind(MemoryKind.episode), isA<Success<void>>());
      expect(store.entries(), isEmpty);
      expect(store.remove('不存在'), isA<Failure<void>>());
    });

    test('原子写：不留 .tmp 残留', () {
      store.add(entry(MemoryKind.task, '周三前交周报'));
      expect(
        tmpDir.listSync().whereType<File>().map((f) => f.path),
        everyElement(isNot(endsWith('.tmp'))),
      );
    });
  });

  group('待确认队列', () {
    test('pending 不注入上下文；接受后生效、拒绝后丢弃', () {
      store.add(
        entry(
          MemoryKind.preference,
          '称呼偏好：老板',
          status: MemoryStatus.pending,
          createdAt: DateTime(2026, 1, 2),
        ),
      );
      store.add(entry(MemoryKind.fact, '喜欢简洁的回复'));

      expect(store.contextFor(now: DateTime(2026, 1, 3)).length, 1);

      final proposal = store.pending.single;
      expect(store.confirm(proposal.id), isA<Success<void>>());
      expect(store.pending, isEmpty);
      expect(store.contextFor(now: DateTime(2026, 1, 3)).length, 2);

      store.add(
        entry(
          MemoryKind.preference,
          '回复保持短句',
          status: MemoryStatus.pending,
          createdAt: DateTime(2026, 1, 4),
        ),
      );
      expect(store.reject(store.pending.single.id), isA<Success<void>>());
      expect(store.pending, isEmpty);
      expect(store.entries().length, 2);
    });
  });

  group('上下文注入', () {
    test('过期记忆不注入，未过期注入', () {
      store.add(
        entry(MemoryKind.fact, '旧任务', expireAt: DateTime(2025, 12, 31)),
      );
      store.add(entry(MemoryKind.fact, '长期作息', expireAt: DateTime(2030, 1, 1)));

      final context = store.contextFor(now: DateTime(2026, 6, 1));
      expect(context.map((e) => e.content), ['长期作息']);
    });

    test('scope=local 不注入', () {
      store.add(entry(MemoryKind.fact, '隐私细节', scope: memoryScopeLocal));
      expect(store.contextFor(now: DateTime(2026, 1, 1)), isEmpty);
    });

    test('kind 优先级 preference > fact > task > episode', () {
      for (final kind in MemoryKind.values) {
        store.add(entry(kind, '条目-${kind.name}'));
      }
      final context = store.contextFor(now: DateTime(2026, 1, 1));
      expect(context.map((e) => e.kind), MemoryKind.values);
    });

    test('同级新者优先，且硬上限 12 条', () {
      for (var i = 0; i < 15; i++) {
        store.add(
          entry(
            MemoryKind.episode,
            '事件$i',
            createdAt: DateTime(2026, 1, 1, 0, i),
          ),
        );
      }
      final context = store.contextFor(now: DateTime(2026, 1, 1));
      expect(context.length, memoryContextMaxCount);
      // 最新的事件0分在前。
      expect(context.first.content, '事件14');
      expect(context.last.content, '事件3');
    });

    test('字符预算 2000 截断', () {
      for (var i = 0; i < 8; i++) {
        store.add(
          entry(
            MemoryKind.fact,
            'f' * 400,
            createdAt: DateTime(2026, 1, 1, 0, i),
          ),
        );
      }
      final context = store.contextFor(now: DateTime(2026, 1, 1));
      expect(context.length, 4); // 第 5 条会到 2005 > 2000，停下。
      expect(
        context.fold<int>(0, (sum, e) => sum + e.content.length + 1) <=
            memoryContextMaxChars,
        isTrue,
      );
    });
  });

  group('导出', () {
    test('导出文件包含全部记忆与导出时间', () {
      store.add(entry(MemoryKind.preference, '称呼偏好：老板'));
      store.add(
        entry(MemoryKind.episode, '一起调试到凌晨', status: MemoryStatus.pending),
      );

      final result = store.export();
      expect(result, isA<Success<File>>());
      final raw = jsonDecode(
        (result as Success<File>).value.readAsStringSync(),
      );
      expect(raw, isA<Map>());
      expect((raw['exportedAt'] as String).isNotEmpty, isTrue);
      expect((raw['entries'] as List).length, 2);
    });
  });

  group('损坏容错', () {
    test('单文件损坏按空库继续，不抛异常，并留档损坏文件', () {
      store.add(entry(MemoryKind.fact, '正常条目'));
      File('${tmpDir.path}/episode.json').writeAsStringSync('{oops');

      final reopened = MemoryStore(directory: tmpDir);
      expect(reopened.entries(kind: MemoryKind.episode), isEmpty);
      expect(reopened.entries(kind: MemoryKind.fact).single.content, '正常条目');
      expect(reopened.loadWarnings.single, contains('episode.json'));
      expect(
        tmpDir.listSync().whereType<File>().any(
          (file) => file.path.contains('episode.json.corrupt-'),
        ),
        isTrue,
      );
    });
  });

  group('记忆治理', () {
    MemoryEntry candidate(String content, {String subject = ''}) => MemoryEntry(
      id: MemoryEntry.newId(DateTime(2026, 1, 2, 12)),
      kind: MemoryKind.task,
      subject: subject,
      content: content,
      createdAt: DateTime(2026, 1, 2, 12),
      source: 'llm',
      status: MemoryStatus.pending,
      confidence: 0.5,
    );

    test('相似的 LLM pending 候选合并，不堆成多条', () {
      store.add(candidate('主人计划重构底层架构，实现自主学习'));
      store.add(candidate('主人计划重构底层系统，实现自主学习能力'));

      expect(store.pending, hasLength(1));
      expect(store.pending.single.content, contains('系统'));
    });

    test('同 subject 的新 active 偏好替代旧条，旧条标 superseded', () {
      store.add(
        MemoryEntry(
          id: 'old-address',
          kind: MemoryKind.preference,
          subject: 'address',
          content: '称呼偏好：老板',
          createdAt: DateTime(2026, 1, 1, 12),
          source: 'rule',
        ),
      );
      store.add(
        MemoryEntry(
          id: 'new-address',
          kind: MemoryKind.preference,
          subject: 'address',
          content: '称呼偏好：主人',
          createdAt: DateTime(2026, 1, 2, 12),
          source: 'rule',
        ),
      );

      final all = store.entries(kind: MemoryKind.preference);
      expect(all, hasLength(2));
      expect(all.first.status, MemoryStatus.superseded);
      expect(all.first.supersededBy, 'new-address');
      expect(
        store.contextFor(now: DateTime(2026, 1, 3)).single.content,
        '称呼偏好：主人',
      );
    });
  });
}
