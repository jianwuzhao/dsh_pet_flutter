/// 反馈采集：把用户的取舍行为记成 append-only 流水（计划 4.5）。
///
/// 反馈**不做 👍/👎 评分**，只有三种语义：
/// - accepted：用户接受了提案/采纳了回复；
/// - rejected：用户拒绝了提案/要求重说/提前关掉主动关心；
/// - corrected：拒绝并附一句纠正（"太长了"），正文进 detail。
/// 自然过期或没有操作一律记中性，不写流水——沉默不是反馈。
library;

import 'dart:convert';
import 'dart:io';

import '../core/paths/app_paths.dart';
import '../core/result.dart';

enum FeedbackVerdict { accepted, rejected, corrected }

/// 反馈目标前缀：memory / reply / care / policy。
/// 具体对象用 `目标:标识`（如 `memory:m123`），策略字段用 `policy:replyLength`。
const String feedbackTargetMemory = 'memory';
const String feedbackTargetReply = 'reply';
const String feedbackTargetCare = 'care';
const String feedbackTargetPolicy = 'policy';

class FeedbackEvent {
  const FeedbackEvent({
    required this.verdict,
    required this.target,
    required this.at,
    this.detail = '',
  });

  final FeedbackVerdict verdict;
  final String target;
  final DateTime at;

  /// 纠正原文；非 corrected 事件为空。
  final String detail;

  factory FeedbackEvent.fromJson(Map<String, dynamic> json) {
    return FeedbackEvent(
      verdict: switch (json['verdict']) {
        'accepted' => FeedbackVerdict.accepted,
        'corrected' => FeedbackVerdict.corrected,
        _ => FeedbackVerdict.rejected,
      },
      target: json['target'] as String? ?? '',
      at:
          DateTime.tryParse(json['at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      detail: json['detail'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'verdict': verdict.name,
    'target': target,
    'at': at.toIso8601String(),
    'detail': detail,
  };
}

class FeedbackCollector {
  FeedbackCollector({File? file, DateTime Function()? clock})
    : _file = file ?? AppPaths.feedbackFile,
      _clock = clock ?? DateTime.now;

  final File _file;
  final DateTime Function() _clock;

  /// 追加一条反馈；写盘失败返回 Failure，但不向上游抛（辅助数据）。
  Result<void> record(
    FeedbackVerdict verdict, {
    required String target,
    String detail = '',
  }) {
    final event = FeedbackEvent(
      verdict: verdict,
      target: target,
      at: _clock(),
      detail: detail.trim(),
    );
    try {
      final parent = _file.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      // append 而不是整体重写：流水只增不改，崩溃也不会丢历史。
      _file.writeAsStringSync(
        '${jsonEncode(event.toJson())}\n',
        mode: FileMode.append,
        flush: true,
      );
      return const Success(null);
    } on Object catch (error) {
      return Failure('feedback.write-failed', '反馈流水写入失败：$error');
    }
  }

  /// 读取全部事件；坏行跳过（流水损坏不该挡住学习与设置页）。
  List<FeedbackEvent> load() {
    try {
      if (!_file.existsSync()) return const [];
      final events = <FeedbackEvent>[];
      for (final line in _file.readAsLinesSync()) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is Map<String, dynamic>) {
            events.add(FeedbackEvent.fromJson(decoded));
          }
        } on FormatException {
          continue;
        }
      }
      return events;
    } on Object {
      return const [];
    }
  }

  /// 统计某目标在某时间窗内的样本数（门禁与自动回滚都用这个口径）。
  /// [target] 可以是前缀（`policy`）或精确值（`policy:replyLength`）。
  int count(
    FeedbackVerdict verdict, {
    required String target,
    Duration window = const Duration(hours: 24),
    DateTime? now,
  }) {
    final at = now ?? _clock();
    final since = at.subtract(window);
    return load()
        .where(
          (event) =>
              event.verdict == verdict &&
              _matchesTarget(event.target, target) &&
              event.at.isAfter(since),
        )
        .length;
  }

  static bool _matchesTarget(String candidate, String query) {
    if (candidate == query) return true;
    // 前缀匹配只在 query 不带分隔符时启用，避免 `policy:a` 命中 `policy:ab`。
    if (query.contains(':')) return false;
    return candidate.startsWith('$query:');
  }
}
