/// 记忆条目：个性化层的长期记忆单元（计划 4.4）。
///
/// 四类记忆各有所长：偏好影响称呼与语气、事实提供背景、任务延续待办、
/// 事件保留情境。写入只有两条路：规则抽取直写 active，LLM 候选必须
/// pending 等用户确认——不做无确认的自动事实写入。
library;

/// 记忆四类：注入优先级 preference > fact > task > episode。
enum MemoryKind { preference, fact, task, episode }

/// 状态：pending 是待用户确认的提案；active 才生效。
/// archived = 过期/长期未用后只保留审计；superseded = 被新偏好替代；
/// disputed = 与另一条记忆冲突，等用户裁决。
enum MemoryStatus { active, pending, archived, superseded, disputed }

/// 注入范围：chat = 可拼进 LLM 上下文；local = 仅本地展示（如含敏感细节）。
const String memoryScopeChat = 'chat';
const String memoryScopeLocal = 'local';

class MemoryEntry {
  const MemoryEntry({
    required this.id,
    required this.kind,
    required this.content,
    required this.createdAt,
    this.subject = '',
    this.scope = memoryScopeChat,
    this.expireAt,
    this.source = 'rule',
    this.status = MemoryStatus.active,
    this.confidence = 1.0,
    this.evidence = const [],
    this.updatedAt,
    this.lastUsedAt,
    this.supersededBy,
    this.conflictGroup,
    this.coreWeight = 0.0,
    this.links = const [],
    this.validFromMs = 0,
    this.validUntilMs = 0,
  });

  final String id;
  final MemoryKind kind;

  /// 稳定主题键（如 address / avoidedTopic / routine / task）。
  /// 有 subject 时，同 kind + subject 的新旧条目可判冲突/替代；
  /// 没有 subject 的条目只能按内容相似度去重。
  final String subject;

  /// 记忆正文（一句话，如“称呼偏好：老板”）。
  final String content;

  /// 使用范围：见 [memoryScopeChat] / [memoryScopeLocal]。
  final String scope;

  /// 过期时间；null = 永久。
  final DateTime? expireAt;

  final DateTime createdAt;

  /// 来源：rule（规则直写）/ llm（模型候选）/ user（用户手动）。
  final String source;

  final MemoryStatus status;

  /// 置信度 0~1：规则抽取高于 LLM 候选；低置信度不直接升级为规则。
  final double confidence;

  /// 证据：session/message/file/命令等可追溯标识。
  final List<String> evidence;

  /// 最近一次内容更新；旧文件没有该字段时回落到 createdAt。
  final DateTime? updatedAt;

  /// 最近一次被注入上下文/被用户查看的时间；用于衰减与归档。
  final DateTime? lastUsedAt;

  /// 被哪条新记忆替代（superseded 时非空）。
  final String? supersededBy;

  /// 冲突组：同一 subject 下互相矛盾的条目共享一个 id。
  final String? conflictGroup;

  /// 核心层权重 0~1：≥0.8 进入 Core 层常驻注入（P1-3 分层）。
  /// 默认 0 = 普通条目，走 Recall 检索或 kind 优先级填充。
  final double coreWeight;

  /// 关联记忆 id 列表：条目间的语义链接（如“称呼偏好”链“沟通偏好”），
  /// 供后续按图扩展召回；本期只存取，不参与注入决策。
  final List<String> links;

  /// 生效窗口（epoch 毫秒）：0 = 不限。窗口外的条目不注入。
  /// 与 expireAt 的区别：expireAt 是“过期作废”，窗口是“还没到/已过季”，
  /// 例如“这周在外地出差”只在出差期间生效。
  final int validFromMs;
  final int validUntilMs;

  bool get isActive => status == MemoryStatus.active;

  DateTime get effectiveUpdatedAt => updatedAt ?? createdAt;

  bool get isExpired {
    final expireAt = this.expireAt;
    return expireAt != null && DateTime.now().isAfter(expireAt);
  }

  /// 进程内自增序列：同一微秒内连续抽取多条也不会撞 id。
  static int _sequence = 0;

  static String newId(DateTime now) =>
      'm${now.microsecondsSinceEpoch}-${_sequence++}';

  factory MemoryEntry.fromJson(Map<String, dynamic> json) {
    return MemoryEntry(
      id: json['id'] as String? ?? '',
      kind: _kindOf(json['kind']),
      subject: json['subject'] as String? ?? '',
      content: json['content'] as String? ?? '',
      scope: json['scope'] as String? ?? memoryScopeChat,
      expireAt: json['expireAt'] is String
          ? DateTime.tryParse(json['expireAt'] as String)
          : null,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      source: json['source'] as String? ?? 'rule',
      status: _statusOf(json['status']),
      confidence: ((json['confidence'] as num?)?.toDouble() ?? 1.0).clamp(
        0.0,
        1.0,
      ),
      evidence: _stringsOf(json['evidence']),
      updatedAt: json['updatedAt'] is String
          ? DateTime.tryParse(json['updatedAt'] as String)
          : null,
      lastUsedAt: json['lastUsedAt'] is String
          ? DateTime.tryParse(json['lastUsedAt'] as String)
          : null,
      supersededBy: json['supersededBy'] as String?,
      conflictGroup: json['conflictGroup'] as String?,
      coreWeight: ((json['coreWeight'] as num?)?.toDouble() ?? 0.0).clamp(
        0.0,
        1.0,
      ),
      links: _stringsOf(json['links']),
      validFromMs: (json['validFromMs'] as num?)?.toInt() ?? 0,
      validUntilMs: (json['validUntilMs'] as num?)?.toInt() ?? 0,
    );
  }

  static MemoryKind _kindOf(Object? raw) => switch (raw) {
    'preference' => MemoryKind.preference,
    'task' => MemoryKind.task,
    'episode' => MemoryKind.episode,
    _ => MemoryKind.fact,
  };

  static MemoryStatus _statusOf(Object? raw) => switch (raw) {
    'pending' => MemoryStatus.pending,
    'archived' => MemoryStatus.archived,
    'superseded' => MemoryStatus.superseded,
    'disputed' => MemoryStatus.disputed,
    _ => MemoryStatus.active,
  };

  static List<String> _stringsOf(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is String && item.trim().isNotEmpty) item.trim(),
    ];
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    if (subject.isNotEmpty) 'subject': subject,
    'content': content,
    'scope': scope,
    if (expireAt != null) 'expireAt': expireAt!.toIso8601String(),
    'createdAt': createdAt.toIso8601String(),
    'source': source,
    'status': status.name,
    'confidence': confidence,
    if (evidence.isNotEmpty) 'evidence': evidence,
    'updatedAt': effectiveUpdatedAt.toIso8601String(),
    if (lastUsedAt != null) 'lastUsedAt': lastUsedAt!.toIso8601String(),
    if (supersededBy != null) 'supersededBy': supersededBy,
    if (conflictGroup != null) 'conflictGroup': conflictGroup,
    // 分层字段仅非默认时写：老库文件保持精简，零值即“普通条目/无窗口”。
    if (coreWeight > 0) 'coreWeight': coreWeight,
    if (links.isNotEmpty) 'links': links,
    if (validFromMs > 0) 'validFromMs': validFromMs,
    if (validUntilMs > 0) 'validUntilMs': validUntilMs,
  };

  MemoryEntry copyWith({
    String? subject,
    String? content,
    String? scope,
    DateTime? expireAt,
    bool clearExpireAt = false,
    MemoryStatus? status,
    double? confidence,
    List<String>? evidence,
    DateTime? updatedAt,
    DateTime? lastUsedAt,
    String? supersededBy,
    bool clearSupersededBy = false,
    String? conflictGroup,
    double? coreWeight,
    List<String>? links,
    int? validFromMs,
    int? validUntilMs,
  }) => MemoryEntry(
    id: id,
    kind: kind,
    subject: subject ?? this.subject,
    content: content ?? this.content,
    scope: scope ?? this.scope,
    expireAt: clearExpireAt ? null : (expireAt ?? this.expireAt),
    createdAt: createdAt,
    source: source,
    status: status ?? this.status,
    confidence: confidence ?? this.confidence,
    evidence: evidence ?? this.evidence,
    updatedAt: updatedAt ?? this.updatedAt,
    lastUsedAt: lastUsedAt ?? this.lastUsedAt,
    supersededBy: clearSupersededBy
        ? null
        : (supersededBy ?? this.supersededBy),
    conflictGroup: conflictGroup ?? this.conflictGroup,
    coreWeight: coreWeight ?? this.coreWeight,
    links: links ?? this.links,
    validFromMs: validFromMs ?? this.validFromMs,
    validUntilMs: validUntilMs ?? this.validUntilMs,
  );
}
