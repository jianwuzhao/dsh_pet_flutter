/// 向量增量同步任务（P1-4）：让向量库跟上 json 主存储。
///
/// 一次 run = prune（删掉主存储里已消失的记忆的残留向量）+ 增量补嵌
/// （只处理 stale：无向量或正文变更的条目），逐条顺序 embed——本地
/// Ollama 扛不住并发，且常态下 stale 为 0～2 条，不值得批量接口。
/// 挂在内核启动/日终维护/每轮对话后：stale 为空时只花一次 SELECT。
library;

import '../../ai/embedding_provider.dart';
import 'memory_entry.dart';
import 'memory_store.dart';
import 'memory_vectors.dart';

class MemoryVectorSync {
  MemoryVectorSync({
    required MemoryStore memory,
    required MemoryVectorStore vectors,
    required EmbeddingProvider Function() embeddingLoader,
  }) : _memory = memory,
       _vectors = vectors,
       _embeddingLoader = embeddingLoader;

  final MemoryStore _memory;
  final MemoryVectorStore _vectors;
  final EmbeddingProvider Function() _embeddingLoader;

  /// 对话后/定时器可能并发触发：后到的直接放弃，下一轮自然会补。
  bool _running = false;

  Future<void> run() async {
    if (_running) return;
    _running = true;
    try {
      if (!_vectors.isAvailable) return;
      final entries = _memory.entries(status: MemoryStatus.active);
      _vectors.prune({for (final entry in entries) entry.id});
      final embedder = _embeddingLoader();
      for (final entry in _vectors.stale(entries)) {
        final vector = await embedder.embed(_embedText(entry));
        // embedding 不可用（开关关/网络断/超时）：放弃本轮剩余补嵌，
        // 已完成的保留——半新半旧没关系，stale 增量下次接着补。
        if (vector == null) return;
        _vectors.upsert(entry, vector);
      }
    } finally {
      _running = false;
    }
  }

  /// 嵌入文本 = subject + 正文：subject 是人工提炼的检索锚点，
  /// 只嵌正文会丢掉“周报→周三交周报”这类主题关联。
  static String _embedText(MemoryEntry entry) =>
      entry.subject.isEmpty ? entry.content : '${entry.subject}。${entry.content}';
}
