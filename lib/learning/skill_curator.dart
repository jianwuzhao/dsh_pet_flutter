/// 技能策展治理层：在 SkillLibrary 存储之上执行 Voyager 式验证闸与预算护栏。
///
/// 状态机与准则三态同构：草案（draft）→ 待确认（pending）→ 生效（active）
/// → 退役（archived，不删文件）。护栏四件套：
/// 1. 证据链：origin_reflection_ids 为空的草案直接丢弃（防编造经验）；
/// 2. 拒绝冷却：被拒草案 24h 内不再提案（冷却从审计流恢复，重启不失效）；
/// 3. 变更预算：每日自动新增提案 ≤3 条，超限只记不入队；
/// 4. 库存上限：非退役技能总数 ≤50，超限必须先退役一个（一进一出）。
/// 所有治理动作追加 skill_events.jsonl（append-only 审计流）。
library;

import 'dart:convert';
import 'dart:io';

import '../ai/skill_library.dart';
import '../core/paths/app_paths.dart';
import '../core/result.dart';

/// 技能治理事件：生成/晋升/拒绝/退役/恢复全留痕。
class SkillEvent {
  const SkillEvent({
    required this.type,
    required this.name,
    required this.at,
    this.version = 0,
    this.reason = '',
  });

  /// proposed / accepted / rejected / retired / reactivated。
  final String type;
  final String name;
  final int version;
  final DateTime at;
  final String reason;

  factory SkillEvent.fromJson(Map<String, dynamic> json) => SkillEvent(
    type: json['type'] as String? ?? '',
    name: json['name'] as String? ?? '',
    version: (json['version'] as num?)?.toInt() ?? 0,
    at:
        DateTime.tryParse(json['at'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    reason: json['reason'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'type': type,
    'name': name,
    'version': version,
    'at': at.toIso8601String(),
    if (reason.isNotEmpty) 'reason': reason,
  };
}

class SkillCurator {
  SkillCurator({
    required SkillLibrary library,
    File? eventsFile,
    int maxSkills = SkillLibrary.maxSkills,
    DateTime Function()? clock,
  }) : _library = library,
       _eventsFile = eventsFile ?? AppPaths.skillEventsFile,
       _maxSkills = maxSkills,
       _clock = clock ?? DateTime.now {
    _restoreCooldowns();
  }

  final SkillLibrary _library;
  final File _eventsFile;
  final int _maxSkills;
  final DateTime Function() _clock;

  /// 每日自动新增提案上限：防自我强化跑偏（越学越提案越多）。
  static const int dailyProposalBudget = 3;

  /// 被拒草案的重复提案冷却（与形态提案冷却同思路，默认值经 D5 确认）。
  static const Duration rejectCooldown = Duration(hours: 24);

  /// 待确认技能上限：提案速率已被日预算约束，这里只是防刷爆的兜底。
  static const int pendingMax = 10;

  /// name → 最近被拒时间：24h 内不再提案同名（重启后从审计流恢复）。
  final Map<String, DateTime> _rejectedAt = {};

  SkillLibrary get library => _library;

  List<SkillManifest> get pending => _library.pending;
  List<SkillManifest> get active => _library.active;

  /// 草案入队：证据链 → 冷却 → 去重 → 日预算 → 库存/待确认上限 → 落库。
  Result<SkillManifest> propose(SkillManifest draft) {
    if (draft.originReflectionIds.isEmpty) {
      return const Failure(
        'skill.untraceable',
        '技能草案缺少可回溯的证据链，已丢弃',
      );
    }
    final now = _clock();
    final rejectedAt = _rejectedAt[draft.name];
    if (rejectedAt != null && now.isBefore(rejectedAt.add(rejectCooldown))) {
      return const Failure('skill.cooldown', '相似草案近期被拒，冷却中');
    }
    if (_isDuplicate(draft)) {
      return const Failure('skill.duplicate', '已有相似技能，未重复入队');
    }
    if (_proposedToday(now) >= dailyProposalBudget) {
      return const Failure('skill.budget', '今日技能提案已达上限，明天再试');
    }
    final liveCount = _library.pending.length + _library.active.length;
    if (liveCount >= _maxSkills) {
      return const Failure('skill.limit', '技能库已满，请先退役一个再新增');
    }
    if (_library.pending.length >= pendingMax) {
      return const Failure('skill.pending-limit', '待确认技能已达上限');
    }
    final saved = _library.save(draft);
    if (saved is Failure<SkillManifest>) return saved;
    _record(SkillEvent(type: 'proposed', name: draft.name, at: now));
    return saved;
  }

  /// 用户确认（Voyager 验证闸）：pending → active。
  Result<SkillManifest> accept(String name) {
    final skill = _library.byName(name);
    if (skill == null || skill.status != SkillStatus.pending) {
      return const Failure('skill.not-found', '这个技能不在待确认队列里');
    }
    final result = _library.setStatus(name, SkillStatus.active);
    if (result is Failure<SkillManifest>) return result;
    _record(
      SkillEvent(
        type: 'accepted',
        name: name,
        version: result.valueOrNull!.version,
        at: _clock(),
      ),
    );
    return result;
  }

  /// 用户拒绝：pending → archived，并进入 24h 冷却。
  Result<void> reject(String name) {
    final skill = _library.byName(name);
    if (skill == null || skill.status != SkillStatus.pending) {
      return const Failure('skill.not-found', '这个技能不在待确认队列里');
    }
    final result = _library.setStatus(name, SkillStatus.archived);
    if (result is Failure<SkillManifest>) {
      return Failure(result.code, result.reason);
    }
    final now = _clock();
    _rejectedAt[name] = now;
    _record(SkillEvent(type: 'rejected', name: name, at: now));
    return const Success(null);
  }

  /// 退役生效技能（停用提案被用户确认后调用）。
  Result<SkillManifest> retire(String name, {String reason = ''}) {
    final skill = _library.byName(name);
    if (skill == null || skill.status != SkillStatus.active) {
      return const Failure('skill.not-found', '这个技能不在生效列表里');
    }
    final result = _library.setStatus(name, SkillStatus.archived);
    if (result is Failure<SkillManifest>) return result;
    _record(
      SkillEvent(
        type: 'retired',
        name: name,
        version: skill.version,
        at: _clock(),
        reason: reason,
      ),
    );
    return result;
  }

  /// 误退役可逆：archived → active（版本与历史不动）。
  Result<SkillManifest> reactivate(String name) {
    final skill = _library.byName(name);
    if (skill == null || skill.status != SkillStatus.archived) {
      return const Failure('skill.not-found', '这个技能不在退役列表里');
    }
    final result = _library.setStatus(name, SkillStatus.active);
    if (result is Failure<SkillManifest>) return result;
    _record(
      SkillEvent(type: 'reactivated', name: name, at: _clock()),
    );
    return result;
  }

  /// 内容去重：与 pending/active 技能的“描述+正文”做 bigram 相似度比较，
  /// 模型换个说法也挡得住（与准则提案同一套口径）。
  bool _isDuplicate(SkillManifest draft) {
    final newBigrams = _bigrams(_normalize('${draft.description}${draft.body}'));
    for (final existing in [..._library.pending, ..._library.active]) {
      final oldBigrams = _bigrams(
        _normalize('${existing.description}${existing.body}'),
      );
      final intersection = newBigrams.intersection(oldBigrams).length;
      final union = newBigrams.union(oldBigrams).length;
      if (union > 0 && intersection / union >= 0.6) return true;
    }
    return false;
  }

  /// 当日已用提案额度：从审计流按天粒度统计，重启不清零。
  int _proposedToday(DateTime now) {
    final dayStart = DateTime(now.year, now.month, now.day);
    return _loadEvents()
        .where(
          (event) =>
              event.type == 'proposed' && !event.at.isBefore(dayStart),
        )
        .length;
  }

  /// 冷却恢复：审计流里最近一次 rejected 事件即冷却起点。
  void _restoreCooldowns() {
    for (final event in _loadEvents()) {
      if (event.type == 'rejected') {
        final known = _rejectedAt[event.name];
        if (known == null || event.at.isAfter(known)) {
          _rejectedAt[event.name] = event.at;
        }
      }
    }
  }

  List<SkillEvent> _loadEvents() {
    try {
      if (!_eventsFile.existsSync()) return const [];
      return [
        for (final line in _eventsFile.readAsLinesSync())
          if (line.trim().isNotEmpty)
            if (tryDecode(line) case final Map<String, dynamic> decoded)
              SkillEvent.fromJson(decoded),
      ];
    } on Object {
      return const [];
    }
  }

  static Map<String, dynamic>? tryDecode(String line) {
    try {
      final decoded = jsonDecode(line);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  void _record(SkillEvent event) {
    try {
      final parent = _eventsFile.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      _eventsFile.writeAsStringSync(
        '${jsonEncode(event.toJson())}\n',
        mode: FileMode.append,
        flush: true,
      );
    } on Object {
      // 审计流写失败不阻塞治理动作本身：状态已在库内正确流转。
    }
  }

  static String _normalize(String text) => text.toLowerCase().replaceAll(
    RegExp(r'[\s，。！？!?、,.：:；;（）()\[\]【】“”「」]'),
    '',
  );

  static Set<String> _bigrams(String text) => {
    for (var index = 0; index + 1 < text.length; index++)
      text.substring(index, index + 2),
  };
}
