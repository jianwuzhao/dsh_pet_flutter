/// 记忆条目：个性化层的长期记忆单元（计划 4.4）。
///
/// 四类记忆各有所长：偏好影响称呼与语气、事实提供背景、任务延续待办、
/// 事件保留情境。写入只有两条路：规则抽取直写 active，LLM 候选必须
/// pending 等用户确认——不做无确认的自动事实写入。
library;

/// 记忆四类：注入优先级 preference > fact > task > episode。
enum MemoryKind { preference, fact, task, episode }

/// 状态：pending 是待用户确认的提案，active 才生效。
enum MemoryStatus { active, pending }

/// 注入范围：chat = 可拼进 LLM 上下文；local = 仅本地展示（如含敏感细节）。
const String memoryScopeChat = 'chat';
const String memoryScopeLocal = 'local';

class MemoryEntry {
  const MemoryEntry({
    required this.id,
    required this.kind,
    required this.content,
    required this.createdAt,
    this.scope = memoryScopeChat,
    this.expireAt,
    this.source = 'rule',
    this.status = MemoryStatus.active,
  });

  final String id;
  final MemoryKind kind;

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
      content: json['content'] as String? ?? '',
      scope: json['scope'] as String? ?? memoryScopeChat,
      expireAt: json['expireAt'] is String
          ? DateTime.tryParse(json['expireAt'] as String)
          : null,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      source: json['source'] as String? ?? 'rule',
      status: json['status'] == 'pending'
          ? MemoryStatus.pending
          : MemoryStatus.active,
    );
  }

  static MemoryKind _kindOf(Object? raw) => switch (raw) {
    'preference' => MemoryKind.preference,
    'task' => MemoryKind.task,
    'episode' => MemoryKind.episode,
    _ => MemoryKind.fact,
  };

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'content': content,
    'scope': scope,
    if (expireAt != null) 'expireAt': expireAt!.toIso8601String(),
    'createdAt': createdAt.toIso8601String(),
    'source': source,
    'status': status.name,
  };

  MemoryEntry copyWith({
    String? content,
    String? scope,
    DateTime? expireAt,
    bool clearExpireAt = false,
    MemoryStatus? status,
  }) => MemoryEntry(
    id: id,
    kind: kind,
    content: content ?? this.content,
    scope: scope ?? this.scope,
    expireAt: clearExpireAt ? null : (expireAt ?? this.expireAt),
    createdAt: createdAt,
    source: source,
    status: status ?? this.status,
  );
}
