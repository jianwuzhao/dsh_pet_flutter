/// 指标基线记录：按天快照核心运行指标（复评报告 Phase 0-6 遗留项）。
///
/// 为什么单独一份文件：会话数、记忆规模、反馈量、policy 版本等指标
/// 散落在各自 store 的“当前值”里，过去了就回看不到；复评验收要求
/// “连续 7 天有数据、能回答这周是否更差”，必须留一条按天的序列。
/// 每天一条 upsert 快照、只保留最近 90 天：覆盖周/月对比，体积有上界。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/paths/app_paths.dart';
import '../core/result.dart';

/// 快照保留天数：验收只需 7 天对比，放宽到 90 天留足回看余量并封顶体积。
const int metricsKeepDays = 90;

/// 一天的指标快照：[date] 是主键，同一天重复 record 直接覆盖（upsert）。
///
/// 快照只存数字：采集口径（会话怎么数、反馈从哪读）由调用方组装，
/// 这里不做任何推断，保证基线口径稳定可比。
class MetricsSnapshot {
  const MetricsSnapshot({
    required this.date,
    required this.recordedAt,
    this.sessions = 0,
    this.memoryActive = 0,
    this.memoryPending = 0,
    this.memoryArchived = 0,
    this.memoryDuplicates = 0,
    this.feedbackCount = 0,
    this.policyVersion = 0,
    this.appearanceRevisions = 0,
  });

  /// YYYY-MM-DD：一天一条的主键，字符串序即时间序。
  final String date;

  /// 会话轮数。
  final int sessions;

  /// 记忆规模：生效 / 待确认 / 已归档 / 近似重复条数。
  final int memoryActive;
  final int memoryPending;
  final int memoryArchived;
  final int memoryDuplicates;

  /// 反馈事件累计数。
  final int feedbackCount;

  /// 策略当前版本号。
  final int policyVersion;

  /// 形象推演累计次数。
  final int appearanceRevisions;

  /// 记录时刻（落盘为 ISO 时间）。
  final DateTime recordedAt;

  /// 容错解析：缺字段一律 0/epoch，坏一条不至于拖垮整份文件。
  factory MetricsSnapshot.fromJson(Map<String, dynamic> json) =>
      MetricsSnapshot(
        date: json['date'] as String? ?? '',
        sessions: (json['sessions'] as num?)?.toInt() ?? 0,
        memoryActive: (json['memoryActive'] as num?)?.toInt() ?? 0,
        memoryPending: (json['memoryPending'] as num?)?.toInt() ?? 0,
        memoryArchived: (json['memoryArchived'] as num?)?.toInt() ?? 0,
        memoryDuplicates: (json['memoryDuplicates'] as num?)?.toInt() ?? 0,
        feedbackCount: (json['feedbackCount'] as num?)?.toInt() ?? 0,
        policyVersion: (json['policyVersion'] as num?)?.toInt() ?? 0,
        appearanceRevisions:
            (json['appearanceRevisions'] as num?)?.toInt() ?? 0,
        recordedAt:
            DateTime.tryParse(json['recordedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );

  /// 全量输出：不省略零值，字段口径稳定便于跨版本对比。
  Map<String, dynamic> toJson() => {
    'date': date,
    'sessions': sessions,
    'memoryActive': memoryActive,
    'memoryPending': memoryPending,
    'memoryArchived': memoryArchived,
    'memoryDuplicates': memoryDuplicates,
    'feedbackCount': feedbackCount,
    'policyVersion': policyVersion,
    'appearanceRevisions': appearanceRevisions,
    'recordedAt': recordedAt.toIso8601String(),
  };
}

/// 指标仓库：learning/metrics.json 的按天快照读写。
///
/// 每次读写都直读文件（一天最多写一条，没必要常驻缓存）；
/// 指标是辅助数据，文件损坏时留档并按空库继续，不挡记录链路。
class MetricsStore {
  MetricsStore({Directory? directory, DateTime Function()? clock})
    : _directory = directory ?? AppPaths.learningDir,
      _clock = clock ?? DateTime.now;

  final Directory _directory;
  final DateTime Function() _clock;

  File get _file =>
      File('${_directory.path}${Platform.pathSeparator}metrics.json');

  /// 写入一天的快照：按 [MetricsSnapshot.date] upsert，
  /// 排序后只保留最近 [metricsKeepDays] 天。
  Result<void> record(MetricsSnapshot snapshot) {
    final snapshots = _readDays();
    final index = snapshots.indexWhere((day) => day.date == snapshot.date);
    if (index >= 0) {
      snapshots[index] = snapshot;
    } else {
      snapshots.add(snapshot);
    }
    snapshots.sort((a, b) => a.date.compareTo(b.date));
    if (snapshots.length > metricsKeepDays) {
      snapshots.removeRange(0, snapshots.length - metricsKeepDays);
    }
    return _writeFile(
      jsonEncode({
        'days': [for (final day in snapshots) day.toJson()],
      }),
    );
  }

  /// 全部快照，按 date 升序（字符串序即时间序）。
  List<MetricsSnapshot> days() => _readDays();

  /// 最近一天的快照：空库返回 null。
  MetricsSnapshot? latest() {
    final snapshots = _readDays();
    if (snapshots.isEmpty) return null;
    return snapshots.last;
  }

  /// 读回快照：文件不存在或结构不对按空库；解析异常先留档再按空库继续。
  List<MetricsSnapshot> _readDays() {
    try {
      if (!_file.existsSync()) return [];
      final raw = jsonDecode(_file.readAsStringSync());
      if (raw is! Map) return [];
      final list = raw['days'];
      if (list is! List) return [];
      return [
        for (final item in list)
          if (item is Map<String, dynamic>) MetricsSnapshot.fromJson(item),
      ]..sort((a, b) => a.date.compareTo(b.date));
    } on Object catch (error) {
      // 损坏不能静默丢：留档供事后排查，同时按空库继续不影响记录。
      debugPrint('[dafishu] 指标文件损坏，已留档并按空库继续：$error');
      _quarantineCorrupt();
      return [];
    }
  }

  /// 原子写：先写 .tmp 再 rename，中途失败不破坏旧快照（与记忆库同一约定）。
  Result<void> _writeFile(String content) {
    try {
      if (!_directory.existsSync()) _directory.createSync(recursive: true);
      final tmp = File('${_file.path}.tmp');
      tmp.writeAsStringSync(content, flush: true);
      tmp.renameSync(_file.path);
      return const Success(null);
    } on Object catch (error) {
      return Failure('metrics.write-failed', '指标写入失败：$error');
    }
  }

  /// 损坏文件改名到 `.corrupt-<timestamp>`：保留证据，下次读取不再重复报错。
  void _quarantineCorrupt() {
    try {
      if (!_file.existsSync()) return;
      final stamp = _clock().millisecondsSinceEpoch;
      _file.renameSync('${_file.path}.corrupt-$stamp');
    } on Object {
      // 改名失败不影响主流程；原文件仍在，下一次读取会再次留痕。
    }
  }
}
