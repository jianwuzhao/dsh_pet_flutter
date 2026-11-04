/// 记忆向量库测试（P1-4）：sqlite_vector 扩展在测试宿主的真实行为。
///
/// 这里不用 fake：向量编码/索引/KNN 都在扩展的 native 代码里，
/// fake 出来的结果验证不了接线正确性——内存库 + 手工小向量足够快。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_pet_flutter/persona/memory/memory_entry.dart';
import 'package:dsh_pet_flutter/persona/memory/memory_vectors.dart';

void main() {
  late MemoryVectorStore store;

  setUp(() {
    store = MemoryVectorStore.openInMemory();
  });

  tearDown(() {
    store.dispose();
  });

  MemoryEntry entry(String id, String content, {MemoryKind kind = MemoryKind.fact}) =>
      MemoryEntry(
        id: id,
        kind: kind,
        content: content,
        createdAt: DateTime(2026, 1, 1),
      );

  test('扩展可用：attach 后 isAvailable，近邻按余弦距离升序', () {
    expect(store.isAvailable, isTrue);

    store.upsert(entry('a', '喜欢简洁回复'), [1.0, 0.0]);
    store.upsert(entry('b', '作息早八'), [0.0, 1.0]);
    store.upsert(entry('c', '喜欢简短邮件'), [0.9, 0.1]);

    final hits = store.nearest([1.0, 0.0], limit: 2);
    expect(hits.length, 2);
    // a 与查询同向（距离≈0），c 次之，b 最远被 limit 排除。
    expect(hits.first.id, 'a');
    expect(hits.last.id, 'c');
    expect(hits.first.distance, lessThan(hits.last.distance));
  });

  test('upsert 同 id 覆盖旧向量', () {
    store.upsert(entry('a', '旧内容'), [1.0, 0.0]);
    store.upsert(entry('a', '新内容'), [0.0, 1.0]);

    final hits = store.nearest([1.0, 0.0]);
    // 旧向量已被覆盖，查询不再命中 a。
    expect(hits, isEmpty);
  });

  test('remove 后不再命中', () {
    store.upsert(entry('a', '喜欢简洁回复'), [1.0, 0.0]);
    store.remove('a');
    expect(store.nearest([1.0, 0.0]), isEmpty);
  });

  test('removeKind 只清对应类别', () {
    store.upsert(entry('f1', '作息早八'), [1.0, 0.0]);
    store.upsert(entry('t1', '周三交周报', kind: MemoryKind.task), [0.9, 0.1]);

    store.removeKind(MemoryKind.task);

    final hits = store.nearest([0.9, 0.1]);
    expect(hits.map((hit) => hit.id), ['f1']);
  });

  test('stale 找出无向量与正文变更的条目', () {
    final changed = entry('a', '称呼：老板');
    store.upsert(entry('a', '称呼：小张'), [1.0, 0.0]);
    store.upsert(entry('b', '作息早八'), [0.0, 1.0]);

    final stale = store.stale([
      changed,
      entry('b', '作息早八'),
      entry('c', '新记忆'),
    ]);
    // a 正文已变更需重嵌，c 还没有向量，b 未变。
    expect(stale.map((item) => item.id), ['a', 'c']);
  });

  test('维度切换（换 embedding 模型）清空旧向量重建索引', () {
    store.upsert(entry('a', '旧模型向量'), [1.0, 0.0]);
    store.upsert(entry('b', '新模型向量'), [0.5, 0.5, 0.5]);

    // 旧向量维度不匹配已被清掉，只有新维度的 b 可查。
    expect(store.nearest([0.5, 0.5, 0.5]).map((hit) => hit.id), ['b']);
    expect(store.nearest([1.0, 0.0]), isEmpty);
    expect(store.stale([entry('a', '旧模型向量')]).map((e) => e.id), ['a']);
  });

  test('切回旧维度复用历史向量，无需重嵌', () {
    final a = entry('a', '旧模型向量');
    store.upsert(a, [1.0, 0.0]);
    store.upsert(entry('b', '新模型向量'), [0.5, 0.5, 0.5]);

    // 一次旧维度写入把库切回（模拟换回旧 embedding 模型）：
    // a 的历史向量仍在旧维度表里，命中第一且 stale 不再要求重嵌。
    store.upsert(entry('c', '切回锚点'), [0.5, 0.5]);
    final hits = store.nearest([1.0, 0.0]);
    expect(hits.first.id, 'a');
    expect(store.stale([a]), isEmpty);
  });

  test('remove 清所有维度表：切回旧模型不会命中已删记忆', () {
    store.upsert(entry('a', '记忆'), [1.0, 0.0]);
    store.upsert(entry('b', '垫背'), [0.5, 0.5, 0.5]);
    store.remove('a');

    // 新条目把库切回旧维度：a 已从所有维度表清除，不能再命中。
    store.upsert(entry('c', '切回'), [0.9, 0.1]);
    expect(store.nearest([1.0, 0.0]).map((hit) => hit.id), isNot(contains('a')));
  });

  test('禁用实例：全部操作 no-op 不抛异常', () {
    final disabled = MemoryVectorStore.disabled();
    expect(disabled.isAvailable, isFalse);
    disabled.upsert(entry('a', '内容'), [1.0, 0.0]);
    expect(disabled.nearest([1.0, 0.0]), isEmpty);
    expect(disabled.stale([entry('a', '内容')]), isEmpty);
    disabled.remove('a');
    disabled.dispose();
  });

  test('contentHash 跨调用稳定且区分内容', () {
    expect(MemoryVectorStore.contentHash('称呼：老板'), 
        MemoryVectorStore.contentHash('称呼：老板'));
    expect(
      MemoryVectorStore.contentHash('称呼：老板'),
      isNot(MemoryVectorStore.contentHash('称呼：小张')),
    );
  });
}
