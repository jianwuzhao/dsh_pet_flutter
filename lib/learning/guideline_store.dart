/// 经验准则：从反思中提炼、经用户确认后才注入 system prompt 的“软规则”。
///
/// 与 PolicyStore 的分工：PolicyStore 只改 4 个表达参数；GuidelineStore
/// 承载“遇到什么情况该怎么做”的文字经验。两者都必须用户接受才生效，
/// 且都不能触碰人格底线/隐私/权限/打扰上限。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/paths/app_paths.dart';
import '../core/result.dart';

enum GuidelineStatus { pending, active, archived }

class Guideline {
  const Guideline({
    required this.id,
    required this.title,
    required this.content,
    required this.createdAt,
    this.trigger = '',
    this.source = 'correction',
    this.status = GuidelineStatus.pending,
    this.version = 0,
    this.useCount = 0,
    this.lastUsedAtMs = 0,
    this.evidence = const [],
    this.approvedAt,
  });

  final String id;
  final String title;

  /// 注入 prompt 的一句话准则。
  final String content;

  /// 触发关键词（| 分隔）；空 = 始终适用。
  final String trigger;

  /// correction / task / manual。
  final String source;
  final GuidelineStatus status;
  final int version;

  /// 被注入 prompt 的次数：有效性追踪的最小信号。
  final int useCount;

  /// 最近一次注入时间（毫秒；0 = 从未用过）。
  final int lastUsedAtMs;

  final List<String> evidence;
  final DateTime createdAt;
  final DateTime? approvedAt;

  factory Guideline.fromJson(Map<String, dynamic> json) => Guideline(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    content: json['content'] as String? ?? '',
    trigger: json['trigger'] as String? ?? '',
    source: json['source'] as String? ?? 'correction',
    status: switch (json['status']) {
      'active' => GuidelineStatus.active,
      'archived' => GuidelineStatus.archived,
      _ => GuidelineStatus.pending,
    },
    version: (json['version'] as num?)?.toInt() ?? 0,
    useCount: (json['useCount'] as num?)?.toInt() ?? 0,
    lastUsedAtMs: (json['lastUsedAtMs'] as num?)?.toInt() ?? 0,
    evidence: _stringsOf(json['evidence']),
    createdAt:
        DateTime.tryParse(json['createdAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    approvedAt: json['approvedAt'] is String
        ? DateTime.tryParse(json['approvedAt'] as String)
        : null,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'content': content,
    if (trigger.isNotEmpty) 'trigger': trigger,
    'source': source,
    'status': status.name,
    'version': version,
    'useCount': useCount,
    'lastUsedAtMs': lastUsedAtMs,
    if (evidence.isNotEmpty) 'evidence': evidence,
    'createdAt': createdAt.toIso8601String(),
    if (approvedAt != null) 'approvedAt': approvedAt!.toIso8601String(),
  };

  Guideline copyWith({
    GuidelineStatus? status,
    int? version,
    int? useCount,
    int? lastUsedAtMs,
    DateTime? approvedAt,
  }) => Guideline(
    id: id,
    title: title,
    content: content,
    trigger: trigger,
    source: source,
    status: status ?? this.status,
    version: version ?? this.version,
    useCount: useCount ?? this.useCount,
    lastUsedAtMs: lastUsedAtMs ?? this.lastUsedAtMs,
    evidence: evidence,
    createdAt: createdAt,
    approvedAt: approvedAt ?? this.approvedAt,
  );

  static List<String> _stringsOf(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is String && item.trim().isNotEmpty) item.trim(),
    ];
  }
}

class GuidelineStore {
  GuidelineStore({Directory? directory})
    : _directory = directory ?? AppPaths.learningDir;

  /// 待确认提案上限：避免反思流水把提案刷爆。
  static const int pendingMax = 20;

  final Directory _directory;
  final List<Guideline> _items = [];

  File get _file =>
      File('${_directory.path}${Platform.pathSeparator}guidelines.json');

  List<Guideline> get pending => _filter(GuidelineStatus.pending);
  List<Guideline> get active => _filter(GuidelineStatus.active);

  /// 当前 prompt 适用的准则：关键词命中的排前面（相关度），
  /// 其次是“始终适用”项；组内新的优先，最多 [max] 条。
  List<Guideline> activeFor(String prompt, {int max = 2}) {
    final text = prompt.toLowerCase();
    final keywordHit = <Guideline>[];
    final always = <Guideline>[];
    for (final item in active) {
      if (item.trigger.trim().isEmpty) {
        always.add(item);
      } else {
        final keywords = item.trigger
            .split(RegExp(r'[|,，、]'))
            .map((word) => word.trim().toLowerCase())
            .where((word) => word.isNotEmpty);
        if (keywords.any(text.contains)) keywordHit.add(item);
      }
    }
    return [...keywordHit, ...always].take(max).toList(growable: false);
  }

  String promptHint(String prompt) {
    final picked = activeFor(prompt);
    if (picked.isEmpty) return '';
    return [for (final item in picked) '- ${item.content}'].join('\n');
  }

  /// 记录一次注入：使用次数 +1、刷新最近使用时间并落盘。
  /// 有效性追踪的最小实现：后续可按“用了却没减少纠正”建议停用。
  void markUsed(Iterable<Guideline> used) {
    var changed = false;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (final item in used) {
      final index = _items.indexWhere((entry) => entry.id == item.id);
      if (index < 0) continue;
      _items[index] = item.copyWith(
        useCount: item.useCount + 1,
        lastUsedAtMs: nowMs,
      );
      changed = true;
    }
    if (changed) _save();
  }

  /// 新提案：先按归一化内容，再按语义相似度去重（模型换个说法也不重复入队）；
  /// 超过上限返回结构化失败。
  Result<void> propose(Guideline guideline) {
    if (guideline.title.trim().isEmpty || guideline.content.trim().isEmpty) {
      return const Failure('guideline.invalid', '准则缺少标题或内容');
    }
    final normalized = _normalize(guideline.content);
    final newBigrams = _bigrams(normalized);
    for (final item in _items) {
      if (item.status == GuidelineStatus.archived) continue;
      if (_normalize(item.content) == normalized) return const Success(null);
      if (_similar(newBigrams, _bigrams(_normalize(item.content)))) {
        return const Success(null);
      }
    }
    if (pending.length >= pendingMax) {
      return const Failure('guideline.pending-limit', '待确认准则已达上限');
    }
    _items.add(guideline);
    return _save();
  }

  Result<Guideline> accept(String id) {
    final index = _items.indexWhere(
      (item) => item.id == id && item.status == GuidelineStatus.pending,
    );
    if (index < 0) {
      return const Failure('guideline.not-found', '这条准则已经不在队列里了');
    }
    final previous = _items[index];
    final next = previous.copyWith(
      status: GuidelineStatus.active,
      version: previous.version + 1,
      approvedAt: DateTime.now(),
    );
    _items[index] = next;
    final saved = _save();
    if (saved is Failure<void>) {
      _items[index] = previous;
      return Failure(saved.code, saved.reason);
    }
    return Success(next);
  }

  Result<void> reject(String id) => _archive(id);

  Result<void> archiveActive(String id) => _archive(id);

  Result<void> _archive(String id) {
    final index = _items.indexWhere((item) => item.id == id);
    if (index < 0) {
      return const Failure('guideline.not-found', '这条准则已经不存在了');
    }
    final previous = _items[index];
    _items[index] = previous.copyWith(status: GuidelineStatus.archived);
    final saved = _save();
    if (saved is Failure<void>) {
      _items[index] = previous;
      return saved;
    }
    return const Success(null);
  }

  List<Guideline> _filter(GuidelineStatus status) => [
    for (final item in _items)
      if (item.status == status) item,
  ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  Result<void> _save() {
    try {
      if (!_directory.existsSync()) _directory.createSync(recursive: true);
      final tmp = File('${_file.path}.tmp');
      tmp.writeAsStringSync(
        jsonEncode({
          'guidelines': [for (final item in _items) item.toJson()],
        }),
        flush: true,
      );
      tmp.renameSync(_file.path);
      return const Success(null);
    } on Object catch (error) {
      return Failure('guideline.write-failed', '准则写入失败：$error');
    }
  }

  void load() {
    _items.clear();
    try {
      if (!_file.existsSync()) return;
      final raw = jsonDecode(_file.readAsStringSync());
      if (raw is! Map) return;
      final list = raw['guidelines'];
      if (list is! List) return;
      _items.addAll([
        for (final item in list)
          if (item is Map<String, dynamic>) Guideline.fromJson(item),
      ]);
    } on Object catch (error) {
      // 准则损坏：按空库继续，但留痕。
      debugPrint('[dafishu] 准则文件损坏，按空库继续：$error');
    }
  }

  static String _normalize(String text) => text.toLowerCase().replaceAll(
    RegExp(r'[\s，。！？!?、,.：:；;（）()\[\]【】“”「」]'),
    '',
  );

  /// 语义去重阈值：字符 bigram Jaccard。比归一化文本宽，比向量相似度严。
  static const double _similarThreshold = 0.6;

  static bool _similar(Set<String> left, Set<String> right) {
    if (left.isEmpty || right.isEmpty) return false;
    final intersection = left.intersection(right).length;
    final union = left.union(right).length;
    return union > 0 && intersection / union >= _similarThreshold;
  }

  static Set<String> _bigrams(String text) => {
    for (var index = 0; index + 1 < text.length; index++)
      text.substring(index, index + 2),
  };
}
