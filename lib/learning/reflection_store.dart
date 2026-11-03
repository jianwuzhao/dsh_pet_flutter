/// 反思流水：任务终态、用户纠正、采纳行为的 append-only 记录。
///
/// 这里只负责“发生过什么”，不做结论；结论由 EvolutionEngine 聚类成
/// 待确认准则。流水坏行跳过，不阻塞对话与学习。
library;

import 'dart:convert';
import 'dart:io';

import '../core/paths/app_paths.dart';
import '../core/result.dart';

/// 反思种类：task=任务终态，correction=用户纠正，feedback=采纳/拒绝。
enum ReflectionKind { task, correction, feedback }

class ReflectionEntry {
  const ReflectionEntry({
    required this.id,
    required this.at,
    required this.kind,
    required this.outcome,
    required this.summary,
    this.source = '',
    this.taskId = '',
    this.intent = '',
    this.rootCause = '',
    this.verification = '',
    this.evidence = const [],
  });

  final String id;
  final DateTime at;
  final ReflectionKind kind;

  /// success / failure / positive / negative。
  final String outcome;
  final String summary;
  final String source;
  final String taskId;

  /// 任务意图（一句话）：让模型知道“当时想做什么”，总结才不会泛泛而谈。
  final String intent;

  /// 失败根因（一句话）：来自用户纠正或后续复盘；未知为空。
  final String rootCause;

  /// 结果验证方式（如 user-accepted / test-passed）；未知为空。
  final String verification;

  final List<String> evidence;

  static int _sequence = 0;

  static String newId(DateTime at) =>
      'r${at.microsecondsSinceEpoch}-${_sequence++}';

  factory ReflectionEntry.fromJson(Map<String, dynamic> json) =>
      ReflectionEntry(
        id: json['id'] as String? ?? '',
        at:
            DateTime.tryParse(json['at'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        kind: switch (json['kind']) {
          'correction' => ReflectionKind.correction,
          'feedback' => ReflectionKind.feedback,
          _ => ReflectionKind.task,
        },
        outcome: json['outcome'] as String? ?? '',
        summary: json['summary'] as String? ?? '',
        source: json['source'] as String? ?? '',
        taskId: json['taskId'] as String? ?? '',
        intent: json['intent'] as String? ?? '',
        rootCause: json['rootCause'] as String? ?? '',
        verification: json['verification'] as String? ?? '',
        evidence: _stringsOf(json['evidence']),
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'at': at.toIso8601String(),
    'kind': kind.name,
    'outcome': outcome,
    'summary': summary,
    if (source.isNotEmpty) 'source': source,
    if (taskId.isNotEmpty) 'taskId': taskId,
    if (intent.isNotEmpty) 'intent': intent,
    if (rootCause.isNotEmpty) 'rootCause': rootCause,
    if (verification.isNotEmpty) 'verification': verification,
    if (evidence.isNotEmpty) 'evidence': evidence,
  };

  static List<String> _stringsOf(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is String && item.trim().isNotEmpty) item.trim(),
    ];
  }
}

class ReflectionStore {
  ReflectionStore({File? file}) : _file = file ?? AppPaths.reflectionFile;

  final File _file;

  Result<void> record(ReflectionEntry entry) {
    try {
      final parent = _file.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      _file.writeAsStringSync(
        '${jsonEncode(entry.toJson())}\n',
        mode: FileMode.append,
        flush: true,
      );
      return const Success(null);
    } on Object catch (error) {
      return Failure('reflection.write-failed', '反思流水写入失败：$error');
    }
  }

  /// 读取全部反思；坏行跳过（流水损坏不该挡住学习）。
  List<ReflectionEntry> load() {
    try {
      if (!_file.existsSync()) return const [];
      final entries = <ReflectionEntry>[];
      for (final line in _file.readAsLinesSync()) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is Map<String, dynamic>) {
            entries.add(ReflectionEntry.fromJson(decoded));
          }
        } on FormatException {
          continue;
        }
      }
      return entries;
    } on Object {
      return const [];
    }
  }

  /// 统计时间窗内同 kind + 同归一化摘要的条数；用于纠正重复检测。
  int countSimilar({
    required ReflectionKind kind,
    required String summary,
    Duration window = const Duration(days: 30),
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    final since = at.subtract(window);
    final normalized = _normalize(summary);
    return load()
        .where(
          (entry) =>
              entry.kind == kind &&
              !entry.at.isBefore(since) &&
              _normalize(entry.summary) == normalized,
        )
        .length;
  }

  static String _normalize(String text) => text.toLowerCase().replaceAll(
    RegExp(r'[\s，。！？!?、,.：:；;（）()\[\]【】“”「」]'),
    '',
  );
}
