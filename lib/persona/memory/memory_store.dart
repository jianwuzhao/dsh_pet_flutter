/// 记忆库：四类记忆的本地 CRUD + 上下文注入 + 导出（计划 4.4）。
///
/// 每类一个 json 文件（memory/{kind}.json），原子写（tmp + rename）。
/// 记忆是辅助数据：单文件损坏时日志留痕并按空库继续，不阻塞对话；
/// 用户权利四件套（查看/纠正/遗忘/导出）全部在这里落地。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/paths/app_paths.dart';
import '../../core/result.dart';
import 'memory_entry.dart';

/// 注入上限（计划 4.4 硬上限）：条数与字符双闸。
const int memoryContextMaxCount = 12;
const int memoryContextMaxChars = 2000;

/// 待确认队列上限：防止 LLM 候选无限堆积（本机已出现过近似重复）。
const int memoryPendingMax = 50;

/// 无 subject 的 LLM 候选去重阈值（字符 bigram Jaccard）。
const double memorySimilarityThreshold = 0.5;

class MemoryStore {
  MemoryStore({Directory? directory})
    : _directory = directory ?? AppPaths.memoryDir {
    _loadAll();
    _consolidateLoadedPending();
  }

  final Directory _directory;
  final Map<MemoryKind, List<MemoryEntry>> _entries = {
    for (final kind in MemoryKind.values) kind: <MemoryEntry>[],
  };

  /// 损坏文件的留痕：损坏文件会被改名保存，读取方至少能看到原因。
  final List<String> _loadWarnings = [];

  List<String> get loadWarnings => List.unmodifiable(_loadWarnings);

  /// 全量读取（含 pending）：设置页查看/导出用。
  List<MemoryEntry> entries({MemoryKind? kind, MemoryStatus? status}) {
    final kinds = kind == null ? MemoryKind.values : [kind];
    return [
      for (final k in kinds)
        for (final entry in _entries[k] ?? const <MemoryEntry>[])
          if (status == null || entry.status == status) entry,
    ];
  }

  /// 待确认队列：LLM 候选提案，接受才生效。
  List<MemoryEntry> get pending =>
      entries(status: MemoryStatus.pending)
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  /// 写入新条目（active 或 pending 均可）。
  ///
  /// 两条治理规则：LLM 候选先与同 kind 的 pending 近似项合并，避免本机
  /// 出现过的“同一件事四种说法”；显式 subject 的新 active 条目会替代旧条，
  /// 旧条不删除，只标 superseded，保证可追溯。
  Result<void> add(MemoryEntry entry) {
    if (entry.id.isEmpty || entry.content.trim().isEmpty) {
      return const Failure('memory.invalid', '记忆条目缺少 id 或内容');
    }
    final list = _entries[entry.kind]!;

    if (entry.status == MemoryStatus.pending && entry.source == 'llm') {
      final similarIndex = _findSimilarPending(list, entry);
      if (similarIndex >= 0) {
        list[similarIndex] = _mergePending(list[similarIndex], entry);
        return _save(entry.kind);
      }
      if (pending.length >= memoryPendingMax) {
        return const Failure(
          'memory.pending-limit',
          '待确认记忆已达上限，先在接受/拒绝队列里处理一批',
        );
      }
    }

    if (entry.status == MemoryStatus.active && entry.subject.isNotEmpty) {
      _supersedeConflicts(list, entry);
    }

    list.add(entry);
    return _save(entry.kind);
  }

  /// 启动时合并历史上已经堆下来的近似 pending（本机曾出现 4 条同义任务）。
  void _consolidateLoadedPending() {
    for (final kind in MemoryKind.values) {
      final source = _entries[kind]!;
      final merged = <MemoryEntry>[];
      var changed = false;
      for (final entry in source) {
        if (entry.status == MemoryStatus.pending && entry.source == 'llm') {
          final index = _findSimilarPending(merged, entry);
          if (index >= 0) {
            merged[index] = _mergePending(merged[index], entry);
            changed = true;
            continue;
          }
        }
        merged.add(entry);
      }
      if (changed) {
        _entries[kind] = merged;
        _save(kind);
        _loadWarnings.add('已合并 ${kind.name} 中的近似待确认候选');
      }
    }
  }

  /// 找同 kind 的近似 pending：先按 subject，再按内容 bigram 相似度。
  int _findSimilarPending(List<MemoryEntry> list, MemoryEntry entry) {
    for (var index = 0; index < list.length; index++) {
      final existing = list[index];
      if (existing.status != MemoryStatus.pending || existing.source != 'llm') {
        continue;
      }
      if (entry.subject.isNotEmpty &&
          existing.subject == entry.subject &&
          _normalize(entry.content) != _normalize(existing.content)) {
        return index;
      }
      if (_similar(entry.content, existing.content)) return index;
    }
    return -1;
  }

  /// 合并两条 pending：保留旧 id/创建时间，采用新正文与更高置信度，
  /// evidence 取并集，updatedAt 记新候选时间。
  MemoryEntry _mergePending(MemoryEntry old, MemoryEntry fresh) {
    final evidence = <String>{
      ...old.evidence,
      ...fresh.evidence,
    }.toList(growable: false);
    return old.copyWith(
      subject: old.subject.isNotEmpty ? old.subject : fresh.subject,
      content: fresh.content,
      confidence: old.confidence > fresh.confidence
          ? old.confidence
          : fresh.confidence,
      evidence: evidence,
      updatedAt: fresh.createdAt,
      lastUsedAt: old.lastUsedAt,
    );
  }

  /// 同 kind + 同 subject 的 active 冲突：旧条标 superseded，新条带 conflictGroup。
  void _supersedeConflicts(List<MemoryEntry> list, MemoryEntry entry) {
    final group = 'cg-${entry.id}';
    for (var index = 0; index < list.length; index++) {
      final existing = list[index];
      if (existing.status != MemoryStatus.active ||
          existing.subject.isEmpty ||
          existing.subject != entry.subject ||
          _normalize(existing.content) == _normalize(entry.content)) {
        continue;
      }
      list[index] = existing.copyWith(
        status: MemoryStatus.superseded,
        supersededBy: entry.id,
        conflictGroup: group,
        updatedAt: entry.createdAt,
      );
    }
  }

  static String _normalize(String text) => text.toLowerCase().replaceAll(
    RegExp(r'[\s，。！？!?、,.：:；;（）()\[\]【】“”「」]'),
    '',
  );

  /// 中文没有天然分词：用字符 bigram 的 Jaccard 作为轻量相似度。
  static bool _similar(String a, String b) {
    final left = _bigrams(_normalize(a));
    final right = _bigrams(_normalize(b));
    if (left.isEmpty || right.isEmpty) return false;
    final intersection = left.intersection(right).length;
    final union = left.union(right).length;
    return union > 0 && intersection / union >= memorySimilarityThreshold;
  }

  static Set<String> _bigrams(String text) => {
    for (var index = 0; index + 1 < text.length; index++)
      text.substring(index, index + 2),
  };

  /// 纠正：按 id 替换内容/范围/时效（用户权利之“纠正”）。
  Result<void> update(MemoryEntry entry) {
    final list = _entries[entry.kind]!;
    final index = list.indexWhere((item) => item.id == entry.id);
    if (index < 0) {
      return Failure('memory.not-found', '记忆 ${entry.id} 不存在，可能已被遗忘');
    }
    list[index] = entry;
    return _save(entry.kind);
  }

  /// 遗忘单条（用户权利之“遗忘”）。
  Result<void> remove(String id) {
    for (final kind in MemoryKind.values) {
      final list = _entries[kind]!;
      if (list.any((entry) => entry.id == id)) {
        list.removeWhere((entry) => entry.id == id);
        return _save(kind);
      }
    }
    return const Failure('memory.not-found', '这条记忆已经不存在了');
  }

  /// 按类清空（用户权利之“遗忘”的整类形态）。
  Result<void> clearKind(MemoryKind kind) {
    _entries[kind]!.clear();
    return _save(kind);
  }

  /// 接受待确认提案：pending → active。
  Result<void> confirm(String id) => _switchStatus(id, MemoryStatus.active);

  /// 拒绝待确认提案：直接丢弃。
  Result<void> reject(String id) => remove(id);

  /// LLM 上下文注入（计划 4.4）：scope 允许 + 未过期 + active，
  /// 按 kind 优先级 preference > fact > task > episode、同级新者优先，
  /// 硬上限 12 条 / 2000 字符。
  List<MemoryEntry> contextFor({DateTime? now}) {
    final at = now ?? DateTime.now();
    final usable = [
      for (final entry in entries(status: MemoryStatus.active))
        if (entry.scope == memoryScopeChat && !isExpiredAt(entry, at)) entry,
    ]..sort(_compareForContext);

    final picked = <MemoryEntry>[];
    var chars = 0;
    for (final entry in usable) {
      if (picked.length >= memoryContextMaxCount) break;
      // 字符预算按“长度 + 换行”计，防止恰好压线后拼出来的上下文超限。
      final cost = entry.content.length + 1;
      if (chars + cost > memoryContextMaxChars) break;
      chars += cost;
      picked.add(entry);
    }
    return picked;
  }

  /// 导出全部记忆到 memory_export.json（用户权利之“导出”）。
  Result<File> export() {
    final file = AppPaths.memoryExportFile;
    switch (_writeFile(
      file,
      jsonEncode({
        'exportedAt': DateTime.now().toIso8601String(),
        'entries': [for (final entry in entries()) entry.toJson()],
      }),
    )) {
      case Success():
        return Success(file);
      case Failure(:final code, :final reason):
        return Failure(code, reason);
    }
  }

  static bool isExpiredAt(MemoryEntry entry, DateTime at) {
    final expireAt = entry.expireAt;
    return expireAt != null && at.isAfter(expireAt);
  }

  /// kind 优先级（preference 最先），同级新者优先（新近度）。
  static int _compareForContext(MemoryEntry a, MemoryEntry b) {
    final byKind = a.kind.index.compareTo(b.kind.index);
    if (byKind != 0) return byKind;
    return b.createdAt.compareTo(a.createdAt);
  }

  Result<void> _switchStatus(String id, MemoryStatus status) {
    for (final kind in MemoryKind.values) {
      final list = _entries[kind]!;
      final index = list.indexWhere((entry) => entry.id == id);
      if (index >= 0) {
        list[index] = list[index].copyWith(status: status);
        return _save(kind);
      }
    }
    return const Failure('memory.not-found', '这条提案已经不在队列里了');
  }

  File _fileFor(MemoryKind kind) =>
      File('${_directory.path}${Platform.pathSeparator}${kind.name}.json');

  Result<void> _save(MemoryKind kind) {
    return _writeFile(
      _fileFor(kind),
      jsonEncode({
        'entries': [for (final entry in _entries[kind]!) entry.toJson()],
      }),
    );
  }

  /// 原子写：先写 .tmp 再 rename，任何一步失败都不碰旧文件语义。
  Result<void> _writeFile(File file, String content) {
    try {
      if (!_directory.existsSync()) _directory.createSync(recursive: true);
      final tmp = File('${file.path}.tmp');
      tmp.writeAsStringSync(content, flush: true);
      tmp.renameSync(file.path);
      return const Success(null);
    } on Object catch (error) {
      return Failure('memory.write-failed', '记忆库写入失败：$error');
    }
  }

  /// 损坏文件改名到 `.corrupt-<timestamp>`：保留证据，同时让下次启动不再重复报错。
  void _quarantineCorrupt(File file) {
    try {
      if (!file.existsSync()) return;
      final stamp = DateTime.now().millisecondsSinceEpoch;
      file.renameSync('${file.path}.corrupt-$stamp');
    } on Object {
      // 改名失败不影响主流程；原文件仍在，下一次启动会再次留痕。
    }
  }

  void _loadAll() {
    for (final kind in MemoryKind.values) {
      final file = _fileFor(kind);
      try {
        if (!file.existsSync()) continue;
        final raw = jsonDecode(file.readAsStringSync());
        if (raw is! Map) continue;
        final list = raw['entries'];
        if (list is! List) continue;
        _entries[kind] = [
          for (final item in list)
            if (item is Map<String, dynamic>) MemoryEntry.fromJson(item),
        ];
      } on Object catch (error) {
        // 辅助数据不能挡住对话主链路，但也不能静默丢：把损坏文件改名留档，
        // 让用户/后续版本还能从 .corrupt 里恢复。
        final warning = '记忆文件 ${kind.name}.json 损坏，已留档：$error';
        _loadWarnings.add(warning);
        debugPrint('[dafishu] $warning');
        _quarantineCorrupt(file);
      }
    }
  }
}
