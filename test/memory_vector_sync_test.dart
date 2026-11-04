/// 向量增量同步任务测试（P1-4c）：全量补嵌 → 增量零调用、prune 清残留、
/// embedding 中断保留已完成、pending 不嵌、禁用库 no-op。
library;

import 'dart:io';

import 'package:dsh_pet_flutter/ai/embedding_provider.dart';
import 'package:dsh_pet_flutter/persona/memory/memory_entry.dart';
import 'package:dsh_pet_flutter/persona/memory/memory_store.dart';
import 'package:dsh_pet_flutter/persona/memory/memory_vector_sync.dart';
import 'package:dsh_pet_flutter/persona/memory/memory_vectors.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可编程假 embedder：计调用次数，可在指定次数时失败一次。
class _FakeEmbedder extends EmbeddingProvider {
  int calls = 0;

  /// 第 N 次调用返回 null（模拟一次失败），0 = 不失败。
  int failAtCall = 0;

  @override
  String get id => 'fake';

  @override
  Future<List<double>?> embed(String text) async {
    calls++;
    if (failAtCall == calls) return null;
    return const [1.0, 0.0];
  }
}

void main() {
  late Directory tmpDir;
  late MemoryStore memory;
  late MemoryVectorStore vectors;
  late _FakeEmbedder embedder;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('memory_vector_sync_test');
    memory = MemoryStore(directory: tmpDir);
    vectors = MemoryVectorStore.openInMemory();
    embedder = _FakeEmbedder();
  });

  tearDown(() {
    vectors.dispose();
    tmpDir.deleteSync(recursive: true);
  });

  MemoryVectorSync buildSync() => MemoryVectorSync(
    memory: memory,
    vectors: vectors,
    embeddingLoader: () => embedder,
  );

  MemoryEntry fact(String id, String content) => MemoryEntry(
    id: id,
    kind: MemoryKind.fact,
    content: content,
    createdAt: DateTime(2026, 1, 1, 12),
  );

  test('首轮全量补嵌，次轮增量零调用', () async {
    memory.add(fact('a', '事实A'));
    memory.add(fact('b', '事实B'));

    await buildSync().run();
    expect(embedder.calls, 2);

    await buildSync().run();
    expect(embedder.calls, 2);
  });

  test('正文变更触发重嵌', () async {
    memory.add(fact('a', '旧内容'));
    await buildSync().run();
    expect(embedder.calls, 1);

    memory.remove('a');
    memory.add(fact('a', '新内容'));
    await buildSync().run();
    expect(embedder.calls, 2);
  });

  test('prune：已删记忆的向量被清，不再命中', () async {
    memory.add(fact('a', '事实A'));
    memory.add(fact('b', '事实B'));
    await buildSync().run();
    expect(vectors.nearest([1.0, 0.0]).map((hit) => hit.id), isNotEmpty);

    memory.remove('a');
    await buildSync().run();
    expect(vectors.nearest([1.0, 0.0]).map((hit) => hit.id), ['b']);
  });

  test('embedding 失败中断本轮，已完成的保留', () async {
    memory.add(fact('a', '事实A'));
    memory.add(fact('b', '事实B'));
    embedder.failAtCall = 1; // 第一次就失败：本轮零补嵌
    await buildSync().run();
    expect(vectors.nearest([1.0, 0.0]), isEmpty);

    await buildSync().run(); // 下一轮补上：1 次失败 + 2 次成功
    expect(embedder.calls, 3);
    expect(vectors.nearest([1.0, 0.0]).length, 2);
  });

  test('pending 条目不嵌：确认入库后下一轮补', () async {
    final pending = fact('p', '待确认')
        .copyWith(status: MemoryStatus.pending);
    memory.add(pending);
    await buildSync().run();
    expect(embedder.calls, 0);
  });

  test('禁用向量库：no-op 且不调 embedding', () async {
    memory.add(fact('a', '事实A'));
    final sync = MemoryVectorSync(
      memory: memory,
      vectors: MemoryVectorStore.disabled(),
      embeddingLoader: () => embedder,
    );
    await sync.run();
    expect(embedder.calls, 0);
  });

  test('subject 参与嵌入文本', () async {
    var lastText = '';
    final recording = _FakeEmbedder();
    final sync = MemoryVectorSync(
      memory: memory,
      vectors: vectors,
      embeddingLoader: () => _RecordingEmbedder(
        delegate: recording,
        onEmbed: (text) => lastText = text,
      ),
    );
    memory.add(
      fact('a', '周三前交').copyWith(subject: '周报'),
    );
    await sync.run();
    expect(lastText, '周报。周三前交');
  });
}

/// 透传记录版：只观测嵌入文本，行为全走被包裹的假 embedder。
class _RecordingEmbedder extends EmbeddingProvider {
  _RecordingEmbedder({required this.delegate, required this.onEmbed});

  final EmbeddingProvider delegate;
  final void Function(String text) onEmbed;

  @override
  String get id => delegate.id;

  @override
  Future<List<double>?> embed(String text) {
    onEmbed(text);
    return delegate.embed(text);
  }
}
