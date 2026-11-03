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

/// 准则变更历史：接受/停用/恢复都追加一条，支撑审计与“恢复到此版”。
class GuidelineRevision {
  const GuidelineRevision({
    required this.version,
    required this.event,
    required this.at,
    this.content = '',
    this.trigger = '',
  });

  /// 该事件后的版本号；archived 不变版本、其余 +1。
  final int version;

  /// accepted / archived / reactivated。
  final String event;
  final DateTime at;

  /// 事件发生时的内容快照：恢复与审计的依据。
  final String content;
  final String trigger;

  factory GuidelineRevision.fromJson(Map<String, dynamic> json) =>
      GuidelineRevision(
        version: (json['version'] as num?)?.toInt() ?? 0,
        event: json['event'] as String? ?? '',
        at:
            DateTime.tryParse(json['at'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        content: json['content'] as String? ?? '',
        trigger: json['trigger'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
    'version': version,
    'event': event,
    'at': at.toIso8601String(),
    if (content.isNotEmpty) 'content': content,
    if (trigger.isNotEmpty) 'trigger': trigger,
  };
}

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
    this.firstInjectedAtMs = 0,
    this.correctedAfterUse = 0,
    this.acceptedAfterUse = 0,
    this.evidence = const [],
    this.history = const [],
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
  /// 即方案里的 lastInjectedAtMs：注入与反馈共用这一个时间锚点。
  final int lastUsedAtMs;

  /// 首次注入时间（毫秒；0 = 从未注入）：区分“先天无效”与“后来失效”。
  final int firstInjectedAtMs;

  /// 注入后 24h 内用户纠正回复的次数（P1-2 有效性回路）。
  final int correctedAfterUse;

  /// 注入后 24h 内用户采纳回复的次数。
  final int acceptedAfterUse;

  final List<String> evidence;
  final DateTime createdAt;
  final DateTime? approvedAt;

  /// 变更留痕：接受/停用/恢复各一条，按时间追加。
  final List<GuidelineRevision> history;

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
    firstInjectedAtMs: (json['firstInjectedAtMs'] as num?)?.toInt() ?? 0,
    correctedAfterUse: (json['correctedAfterUse'] as num?)?.toInt() ?? 0,
    acceptedAfterUse: (json['acceptedAfterUse'] as num?)?.toInt() ?? 0,
    evidence: _stringsOf(json['evidence']),
    history: _revisionsOf(json['history']),
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
    'firstInjectedAtMs': firstInjectedAtMs,
    'correctedAfterUse': correctedAfterUse,
    'acceptedAfterUse': acceptedAfterUse,
    if (evidence.isNotEmpty) 'evidence': evidence,
    if (history.isNotEmpty)
      'history': [for (final revision in history) revision.toJson()],
    'createdAt': createdAt.toIso8601String(),
    if (approvedAt != null) 'approvedAt': approvedAt!.toIso8601String(),
  };

  Guideline copyWith({
    GuidelineStatus? status,
    int? version,
    int? useCount,
    int? lastUsedAtMs,
    int? firstInjectedAtMs,
    int? correctedAfterUse,
    int? acceptedAfterUse,
    List<GuidelineRevision>? history,
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
    firstInjectedAtMs: firstInjectedAtMs ?? this.firstInjectedAtMs,
    correctedAfterUse: correctedAfterUse ?? this.correctedAfterUse,
    acceptedAfterUse: acceptedAfterUse ?? this.acceptedAfterUse,
    evidence: evidence,
    history: history ?? this.history,
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

  static List<GuidelineRevision> _revisionsOf(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map<String, dynamic>) GuidelineRevision.fromJson(item),
    ];
  }
}

/// 停用提案（P1-2 有效性回路）：注入后纠正占比过高的 active 准则，
/// 生成“建议停用”的待确认项。接受才归档；拒绝则保留准则并清掉提案。
class GuidelineRetireProposal {
  const GuidelineRetireProposal({
    required this.id,
    required this.guidelineId,
    required this.title,
    required this.content,
    required this.reason,
    required this.createdAt,
  });

  final String id;

  /// 指向的准则 id：接受时归档它。
  final String guidelineId;

  /// 展示快照：提案可能比准则先出队，留快照避免空引用。
  final String title;
  final String content;

  /// 给用户看的判定依据（注入/纠正统计）。
  final String reason;
  final DateTime createdAt;

  factory GuidelineRetireProposal.fromJson(Map<String, dynamic> json) =>
      GuidelineRetireProposal(
        id: json['id'] as String? ?? '',
        guidelineId: json['guidelineId'] as String? ?? '',
        title: json['title'] as String? ?? '',
        content: json['content'] as String? ?? '',
        reason: json['reason'] as String? ?? '',
        createdAt:
            DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'guidelineId': guidelineId,
    'title': title,
    'content': content,
    'reason': reason,
    'createdAt': createdAt.toIso8601String(),
  };
}

class GuidelineStore {
  GuidelineStore({Directory? directory})
    : _directory = directory ?? AppPaths.learningDir;

  /// 待确认提案上限：避免反思流水把提案刷爆。
  static const int pendingMax = 20;

  /// 注入与反馈的归因窗口：反馈只归到 24h 内注入过的准则上。
  static const Duration outcomeWindow = Duration(hours: 24);

  /// 停用线（保守）：注入 ≥5 次且注入后纠正占比 ≥40% 才建议停用。
  static const int retireMinUseCount = 5;
  static const double retireCorrectionShare = 0.4;

  /// 停用提案上限：无效准则集中爆发时也不刷屏。
  static const int retireProposalsMax = 10;

  final Directory _directory;
  final List<Guideline> _items = [];
  final List<GuidelineRetireProposal> _retireProposals = [];

  /// 拒绝过的停用提案（guidelineId，仅内存）：用户说了“保留”，
  /// 本次运行内不再自动重提；重启后若仍达标可再提。
  final Set<String> _rejectedRetireIds = {};

  File get _file =>
      File('${_directory.path}${Platform.pathSeparator}guidelines.json');

  List<Guideline> get pending => _filter(GuidelineStatus.pending);
  List<Guideline> get active => _filter(GuidelineStatus.active);
  List<Guideline> get archived => _filter(GuidelineStatus.archived);

  /// 待确认的停用提案（P1-2）：只建议，接受与否都在用户。
  List<GuidelineRetireProposal> get retireProposals =>
      List.unmodifiable(_retireProposals);

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
        firstInjectedAtMs: item.firstInjectedAtMs == 0
            ? nowMs
            : item.firstInjectedAtMs,
      );
      changed = true;
    }
    if (changed) _save();
  }

  /// 反馈回填（P1-2）：回复被采纳/纠正时，反查 [outcomeWindow] 内
  /// 注入过的 active 准则，把结果累到对应计数，再扫一遍停用线。
  /// 返回本次新生成的停用提案（调用方可用于气泡提醒）。
  List<GuidelineRetireProposal> recordInjectionOutcome({
    required bool accepted,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    final windowStartMs = at.subtract(outcomeWindow).millisecondsSinceEpoch;
    final atMs = at.millisecondsSinceEpoch;
    var changed = false;
    for (var index = 0; index < _items.length; index++) {
      final item = _items[index];
      if (item.status != GuidelineStatus.active) continue;
      // 时间对不上就不归因：未注入过、注入太久、或“未来”注入（时钟回拨）。
      if (item.lastUsedAtMs <= 0 ||
          item.lastUsedAtMs < windowStartMs ||
          item.lastUsedAtMs > atMs) {
        continue;
      }
      _items[index] = item.copyWith(
        correctedAfterUse: item.correctedAfterUse + (accepted ? 0 : 1),
        acceptedAfterUse: item.acceptedAfterUse + (accepted ? 1 : 0),
      );
      changed = true;
    }
    if (!changed) return const [];
    if (_save() is Failure<void>) return const [];
    return _proposeRetire(at);
  }

  /// 扫停用线并生成提案：useCount ≥ [retireMinUseCount] 且
  /// 注入后纠正占比 ≥ [retireCorrectionShare]。同一准则不重复提案。
  List<GuidelineRetireProposal> _proposeRetire(DateTime at) {
    final existing = {
      for (final proposal in _retireProposals) proposal.guidelineId,
    };
    final created = <GuidelineRetireProposal>[];
    for (final item in active) {
      if (existing.contains(item.id) || _rejectedRetireIds.contains(item.id)) {
        continue;
      }
      final total = item.correctedAfterUse + item.acceptedAfterUse;
      if (item.useCount < retireMinUseCount || total == 0) continue;
      if (item.correctedAfterUse / total < retireCorrectionShare) continue;
      final proposal = GuidelineRetireProposal(
        id: 'retire-${item.id}',
        guidelineId: item.id,
        title: item.title,
        content: item.content,
        reason:
            '已注入 ${item.useCount} 次；'
            '$total 次反馈中纠正 ${item.correctedAfterUse} 次'
            '（${(item.correctedAfterUse / total * 100).round()}%）',
        createdAt: at,
      );
      _retireProposals.add(proposal);
      created.add(proposal);
    }
    if (created.isEmpty) return created;
    if (_retireProposals.length > retireProposalsMax) {
      // 超限丢最旧的：新证据比旧提案更有代表性。
      _retireProposals.removeRange(
        0,
        _retireProposals.length - retireProposalsMax,
      );
    }
    _save();
    return created;
  }

  /// 接受停用提案：归档目标准则（历史记 retired，版本不变），提案出队。
  Result<void> acceptRetire(String proposalId) {
    final index = _retireProposals.indexWhere(
      (proposal) => proposal.id == proposalId,
    );
    if (index < 0) {
      return const Failure('guideline.not-found', '这条停用提案已经不在队列里了');
    }
    final proposal = _retireProposals.removeAt(index);
    final archived = _archive(proposal.guidelineId, event: 'retired');
    if (archived is Failure<void>) {
      // 归档失败连提案一起回滚，保持队列与准则状态一致。
      _retireProposals.insert(index, proposal);
      return archived;
    }
    _save();
    return const Success(null);
  }

  /// 拒绝停用提案：准则保持 active，提案出队且本次运行不再重提。
  Result<void> rejectRetire(String proposalId) {
    final index = _retireProposals.indexWhere(
      (proposal) => proposal.id == proposalId,
    );
    if (index < 0) {
      return const Failure('guideline.not-found', '这条停用提案已经不在队列里了');
    }
    final proposal = _retireProposals.removeAt(index);
    _rejectedRetireIds.add(proposal.guidelineId);
    final saved = _save();
    if (saved is Failure<void>) {
      _retireProposals.insert(index, proposal);
      _rejectedRetireIds.remove(proposal.guidelineId);
      return saved;
    }
    return const Success(null);
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
    final at = DateTime.now();
    final next = previous.copyWith(
      status: GuidelineStatus.active,
      version: previous.version + 1,
      approvedAt: at,
      history: [
        ...previous.history,
        GuidelineRevision(
          version: previous.version + 1,
          event: 'accepted',
          at: at,
          content: previous.content,
          trigger: previous.trigger,
        ),
      ],
    );
    _items[index] = next;
    final saved = _save();
    if (saved is Failure<void>) {
      _items[index] = previous;
      return Failure(saved.code, saved.reason);
    }
    return Success(next);
  }

  /// 恢复已停用准则：archived → active，版本 +1，历史记 reactivated。
  /// 误停用是可逆操作；恢复同样只回到“注入 prompt”，不自动做别的。
  Result<Guideline> reactivate(String id) {
    final index = _items.indexWhere(
      (item) => item.id == id && item.status == GuidelineStatus.archived,
    );
    if (index < 0) {
      return const Failure('guideline.not-found', '这条准则不在已停用列表里');
    }
    final previous = _items[index];
    final at = DateTime.now();
    final next = previous.copyWith(
      status: GuidelineStatus.active,
      version: previous.version + 1,
      approvedAt: at,
      history: [
        ...previous.history,
        GuidelineRevision(
          version: previous.version + 1,
          event: 'reactivated',
          at: at,
          content: previous.content,
          trigger: previous.trigger,
        ),
      ],
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

  /// 归档（手动停用/拒绝提案记 archived；接受停用提案记 retired，
  /// 便于审计时区分“用户主动停”与“有效性回路建议停”）。
  Result<void> _archive(String id, {String event = 'archived'}) {
    final index = _items.indexWhere((item) => item.id == id);
    if (index < 0) {
      return const Failure('guideline.not-found', '这条准则已经不存在了');
    }
    final previous = _items[index];
    if (previous.status == GuidelineStatus.archived) {
      return const Success(null);
    }
    final at = DateTime.now();
    final next = previous.copyWith(
      status: GuidelineStatus.archived,
      history: [
        ...previous.history,
        GuidelineRevision(
          version: previous.version,
          event: event,
          at: at,
          content: previous.content,
          trigger: previous.trigger,
        ),
      ],
    );
    _items[index] = next;
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
          if (_retireProposals.isNotEmpty)
            'retireProposals': [
              for (final proposal in _retireProposals) proposal.toJson(),
            ],
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
    _retireProposals.clear();
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
      final proposals = raw['retireProposals'];
      if (proposals is List) {
        _retireProposals.addAll([
          for (final item in proposals)
            if (item is Map<String, dynamic>)
              GuidelineRetireProposal.fromJson(item),
        ]);
      }
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
