/// 技能库（Agent Skills 规范的存储层）：可检索、可版本化、可退役的结构化经验。
///
/// 与准则的分工：Guideline 是“别做什么”的一句话；Skill 是“怎么做”的
/// 多步程序性知识，因此技能必须带 triggers——没有触发场景的做法无法
/// 检索，也不该常驻注入。渐进加载三级：index.json 元数据常驻 →
/// triggers 命中读 SKILL.md 正文 → 按需读 examples.md。
///
/// 本文件只管存储与检索；生成预算、拒绝冷却等治理规则在 skill_curator。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/paths/app_paths.dart';
import '../core/result.dart';

/// 技能种类：procedural=怎么做（多步），preference=偏好，fact=事实。
enum SkillKind { procedural, preference, fact }

/// 与准则三态同构：pending 待确认、active 生效、archived 退役不删文件。
enum SkillStatus { pending, active, archived }

/// 技能清单：frontmatter 字段 + 运行时统计（useCount 等只进 index.json）。
class SkillManifest {
  const SkillManifest({
    required this.name,
    required this.description,
    required this.triggers,
    required this.body,
    required this.createdAt,
    this.kind = SkillKind.procedural,
    this.source = 'task-reflection',
    this.originReflectionIds = const [],
    this.version = 1,
    this.status = SkillStatus.pending,
    this.useCount = 0,
    this.lastUsedAtMs = 0,
    this.approvedAt,
    this.archivedAt,
  });

  /// 唯一 id，kebab-case：同时是技能目录名。
  final String name;

  /// 一句话索引行（≤80 字）：常驻 system prompt 的全部可见信息。
  final String description;

  /// 触发关键词（| 或逗号分隔）。技能必须可检索，不允许“始终适用”。
  final String triggers;

  /// 正文（≤300 字）：命中 triggers 后才注入的做法说明。
  final String body;

  /// task-reflection / correction-cluster / manual。
  final String source;

  /// 证据链：源自哪些反思条目；不可回溯的草案在治理层直接丢弃。
  final List<String> originReflectionIds;
  final SkillKind kind;
  final int version;
  final SkillStatus status;
  final DateTime createdAt;

  /// 用户确认时间 / 退役时间：写入 SKILL.md frontmatter，
  /// 索引损坏按技能目录重建时靠它们恢复三态。
  final DateTime? approvedAt;
  final DateTime? archivedAt;

  /// 注入次数与最近注入时间：有效性追踪的最小信号（与准则同口径）。
  final int useCount;
  final int lastUsedAtMs;

  factory SkillManifest.fromJson(Map<String, dynamic> json) => SkillManifest(
    name: json['name'] as String? ?? '',
    description: json['description'] as String? ?? '',
    triggers: json['triggers'] as String? ?? '',
    body: json['body'] as String? ?? '',
    kind: switch (json['kind']) {
      'preference' => SkillKind.preference,
      'fact' => SkillKind.fact,
      _ => SkillKind.procedural,
    },
    version: (json['version'] as num?)?.toInt() ?? 1,
    source: json['source'] as String? ?? 'task-reflection',
    originReflectionIds: _stringsOf(json['origin_reflection_ids']),
    status: switch (json['status']) {
      'active' => SkillStatus.active,
      'archived' => SkillStatus.archived,
      _ => SkillStatus.pending,
    },
    useCount: (json['useCount'] as num?)?.toInt() ?? 0,
    lastUsedAtMs: (json['lastUsedAtMs'] as num?)?.toInt() ?? 0,
    createdAt:
        DateTime.tryParse(json['created_at'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    approvedAt: _dateOf(json['approved_at']),
    archivedAt: _dateOf(json['archived_at']),
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'triggers': triggers,
    'kind': kind.name,
    'version': version,
    'source': source,
    if (originReflectionIds.isNotEmpty)
      'origin_reflection_ids': originReflectionIds,
    'status': status.name,
    'useCount': useCount,
    'lastUsedAtMs': lastUsedAtMs,
    'created_at': createdAt.toIso8601String(),
    if (approvedAt != null) 'approved_at': approvedAt!.toIso8601String(),
    if (archivedAt != null) 'archived_at': archivedAt!.toIso8601String(),
    // body 只进 SKILL.md，索引不存正文——渐进加载的前提。
    if (body.isNotEmpty) 'body': body,
  };

  SkillManifest copyWith({
    String? description,
    String? triggers,
    String? body,
    int? version,
    SkillStatus? status,
    int? useCount,
    int? lastUsedAtMs,
    DateTime? createdAt,
    DateTime? approvedAt,
    DateTime? archivedAt,
  }) => SkillManifest(
    name: name,
    description: description ?? this.description,
    triggers: triggers ?? this.triggers,
    body: body ?? this.body,
    createdAt: createdAt ?? this.createdAt,
    kind: kind,
    source: source,
    originReflectionIds: originReflectionIds,
    version: version ?? this.version,
    status: status ?? this.status,
    useCount: useCount ?? this.useCount,
    lastUsedAtMs: lastUsedAtMs ?? this.lastUsedAtMs,
    approvedAt: approvedAt ?? this.approvedAt,
    archivedAt: archivedAt ?? this.archivedAt,
  );

  static List<String> _stringsOf(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is String && item.trim().isNotEmpty) item.trim(),
    ];
  }

  static DateTime? _dateOf(Object? raw) =>
      raw is String ? DateTime.tryParse(raw) : null;
}

/// 一次 system prompt 注入包：常驻索引行 + 命中展开的正文。
///
/// 索引行让模型知道“有哪些技能”；正文只在用户消息命中 triggers 时
/// 展开——这是渐进加载第一、二级在 prompt 侧的体现。
class SkillInjection {
  const SkillInjection({required this.index, required this.expanded});

  /// 常驻索引（useCount Top 5）：进模型视野靠注入次数竞争。
  final List<SkillManifest> index;

  /// triggers 命中当前消息的技能：正文随注入展开。
  final List<SkillManifest> expanded;
}

class SkillLibrary {
  SkillLibrary({Directory? directory, DateTime Function()? clock})
    : _directory = directory ?? AppPaths.skillsDir,
      _clock = clock ?? DateTime.now;

  final Directory _directory;
  final DateTime Function() _clock;

  /// name → 技能；装载后常驻内存，正文按需读盘。
  final Map<String, SkillManifest> _index = {};

  /// 技能总数上限：超过必须先退役一个（治理层执行一进一出，
  /// 这里只暴露计数，避免库层长出治理规则）。
  static const int maxSkills = 50;

  static final RegExp _kebabCase = RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$');

  /// 内容字段的兜底截断：生成侧已限制长度，这里防异常输入撑爆 prompt。
  static const int maxDescriptionChars = 80;
  static const int maxBodyChars = 300;

  File get _indexFile =>
      File('${_directory.path}${Platform.pathSeparator}index.json');

  Directory _skillDir(String name) =>
      Directory('${_directory.path}${Platform.pathSeparator}$name');

  File _skillFile(String name) =>
      File('${_skillDir(name).path}${Platform.pathSeparator}SKILL.md');

  List<SkillManifest> get all => _index.values.toList(growable: false);
  List<SkillManifest> get pending => _byStatus(SkillStatus.pending);
  List<SkillManifest> get active => _byStatus(SkillStatus.active);
  List<SkillManifest> get archived => _byStatus(SkillStatus.archived);

  SkillManifest? byName(String name) => _index[name];

  int get activeCount => active.length;

  /// 装载：优先读 index.json；索引损坏或缺失时扫描技能目录重建。
  /// 重建依据 SKILL.md frontmatter 恢复三态（approvedAt/archivedAt），
  /// 两者都失败按空库继续——技能段不注入，对话降级为现状。
  void load() {
    _index.clear();
    if (_tryLoadIndex()) return;
    if (_rebuildFromSkillDirs()) return;
    _index.clear();
  }

  bool _tryLoadIndex() {
    try {
      if (!_indexFile.existsSync()) return false;
      final decoded = jsonDecode(_indexFile.readAsStringSync());
      if (decoded is! Map) return false;
      final list = decoded['skills'];
      if (list is! List) return false;
      for (final item in list) {
        if (item is! Map<String, dynamic>) continue;
        final skill = SkillManifest.fromJson(item);
        if (skill.name.isNotEmpty) _index[skill.name] = skill;
      }
      return true;
    } on Object catch (error) {
      debugPrint('[dafishu] 技能索引损坏，尝试按技能目录重建：$error');
      return false;
    }
  }

  /// 索引坏了但技能目录还在：逐个解析 SKILL.md 重建并写回索引。
  bool _rebuildFromSkillDirs() {
    try {
      if (!_directory.existsSync()) return false;
      var rebuiltAny = false;
      for (final entity in _directory.listSync()) {
        if (entity is! Directory) continue;
        final file = File(
          '${entity.path}${Platform.pathSeparator}SKILL.md',
        );
        if (!file.existsSync()) continue;
        final parsed = parseSkillMd(file.readAsStringSync());
        if (parsed == null) continue;
        // frontmatter 没有 useCount：运行时统计随坏索引丢失，从零重计。
        _index[parsed.name] = parsed;
        rebuiltAny = true;
      }
      if (!rebuiltAny) return false;
      // 重建结果立即落盘，避免每次启动都重扫目录。
      return _saveIndex() is Success<void>;
    } on Object catch (error) {
      debugPrint('[dafishu] 技能目录重建失败，按空库继续：$error');
      return false;
    }
  }

  /// 检索（渐进加载第一级）：active 且 triggers 命中当前消息的技能，
  /// 新的优先，最多 [max] 条。
  List<SkillManifest> match(String prompt, {int max = 5}) {
    final text = prompt.toLowerCase();
    final hits = [
      for (final skill in active)
        if (_hitTriggers(skill, text)) skill,
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return hits.take(max).toList(growable: false);
  }

  static bool _hitTriggers(SkillManifest skill, String lowercasedPrompt) {
    final keywords = skill.triggers
        .split(RegExp(r'[|,，、]'))
        .map((word) => word.trim().toLowerCase())
        .where((word) => word.length >= 2);
    return keywords.any(lowercasedPrompt.contains);
  }

  /// 渐进加载第二级：命中技能读正文。失败返回 null（不注入正文）。
  String? readBody(String name) {
    final cached = _index[name]?.body;
    if (cached != null && cached.isNotEmpty) return cached;
    try {
      final file = _skillFile(name);
      if (!file.existsSync()) return null;
      final parsed = parseSkillMd(file.readAsStringSync());
      return parsed?.body;
    } on Object {
      return null;
    }
  }

  /// 渐进加载第三级：可选的扩展示例文件，不存在返回 null。
  String? readExtra(String name) {
    try {
      final file = File(
        '${_skillDir(name).path}${Platform.pathSeparator}examples.md',
      );
      if (!file.existsSync()) return null;
      final text = file.readAsStringSync().trim();
      return text.isEmpty ? null : text;
    } on Object {
      return null;
    }
  }

  /// 新增/修订技能：内容有实质变化时版本 +1，旧正文移入技能内 history/。
  /// 状态与统计字段变化不触发版本递增（版本只跟内容走）。
  Result<SkillManifest> save(SkillManifest input) {
    final name = input.name.trim();
    if (!_kebabCase.hasMatch(name)) {
      return const Failure('skill.invalid-name', '技能名必须是 kebab-case');
    }
    final description = _clip(input.description.trim(), maxDescriptionChars);
    final body = _clip(input.body.trim(), maxBodyChars);
    final triggers = input.triggers.trim();
    if (description.isEmpty || body.isEmpty || triggers.isEmpty) {
      return const Failure('skill.invalid', '技能缺少描述、正文或触发词');
    }

    final existing = _index[name];
    // 首次入库版本从 1 起；修订时统一在此递增，调用方不必各自记版本号。
    var next = input.copyWith(description: description, body: body);
    if (existing != null) {
      final contentChanged =
          existing.description != description ||
          existing.body != body ||
          existing.triggers != triggers;
      if (!contentChanged) {
        // 幂等：只同步治理状态，使用统计以库内为准（input 可能是旧快照）。
        next = existing.copyWith(
          status: input.status,
          approvedAt: input.approvedAt,
          archivedAt: input.archivedAt,
        );
      } else {
        // 修订换内容但不清零使用计数：版本历史与有效性统计各自独立演进。
        next = input.copyWith(
          description: description,
          body: body,
          version: existing.version + 1,
          createdAt: existing.createdAt,
          useCount: existing.useCount,
          lastUsedAtMs: existing.lastUsedAtMs,
          approvedAt: input.approvedAt ?? existing.approvedAt,
          archivedAt: input.archivedAt ?? existing.archivedAt,
          status: input.status,
        );
        final moved = _archivePreviousVersion(name, existing.version);
        if (moved is Failure<void>) return Failure(moved.code, moved.reason);
      }
    }

    final written = _writeSkillMd(next);
    if (written is Failure<void>) return Failure(written.code, written.reason);
    _index[name] = next;
    final saved = _saveIndex();
    if (saved is Failure<void>) {
      _index.remove(name);
      return Failure(saved.code, saved.reason);
    }
    return Success(next);
  }

  /// 三态流转：晋升 active 记 approvedAt，退役记 archivedAt（不删文件）。
  Result<SkillManifest> setStatus(String name, SkillStatus status) {
    final existing = _index[name];
    if (existing == null) {
      return const Failure('skill.not-found', '这个技能不存在');
    }
    final now = _clock();
    final next = existing.copyWith(
      status: status,
      approvedAt: status == SkillStatus.active
          ? (existing.approvedAt ?? now)
          : existing.approvedAt,
      archivedAt: status == SkillStatus.archived ? now : existing.archivedAt,
    );
    final written = _writeSkillMd(next);
    if (written is Failure<void>) return Failure(written.code, written.reason);
    _index[name] = next;
    final saved = _saveIndex();
    if (saved is Failure<void>) {
      _index[name] = existing;
      return Failure(saved.code, saved.reason);
    }
    return Success(next);
  }

  /// 记录一次注入（正文级）：计数与最近使用时间落盘。
  void markUsed(Iterable<SkillManifest> used) {
    var changed = false;
    final nowMs = _clock().millisecondsSinceEpoch;
    for (final skill in used) {
      final existing = _index[skill.name];
      if (existing == null) continue;
      _index[skill.name] = existing.copyWith(
        useCount: existing.useCount + 1,
        lastUsedAtMs: nowMs,
      );
      changed = true;
    }
    if (changed) _saveIndex();
  }

  /// 把当前版本的 SKILL.md 移入 history/：修订留痕，可手工找回任意旧版。
  Result<void> _archivePreviousVersion(String name, int version) {
    try {
      final file = _skillFile(name);
      if (!file.existsSync()) return const Success(null);
      final history = Directory(
        '${_skillDir(name).path}${Platform.pathSeparator}history',
      );
      if (!history.existsSync()) history.createSync(recursive: true);
      file.renameSync(
        '${history.path}${Platform.pathSeparator}SKILL.v$version.md',
      );
      return const Success(null);
    } on Object catch (error) {
      return Failure('skill.history-failed', '旧版本归档失败：$error');
    }
  }

  Result<void> _writeSkillMd(SkillManifest skill) {
    try {
      final dir = _skillDir(skill.name);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _skillFile(skill.name).writeAsStringSync(
        encodeSkillMd(skill),
        flush: true,
      );
      return const Success(null);
    } on Object catch (error) {
      return Failure('skill.write-failed', '技能写入失败：$error');
    }
  }

  Result<void> _saveIndex() {
    try {
      if (!_directory.existsSync()) _directory.createSync(recursive: true);
      final tmp = File('${_indexFile.path}.tmp');
      tmp.writeAsStringSync(
        jsonEncode({
          'skills': [for (final skill in _index.values) skill.toJson()],
        }),
        flush: true,
      );
      tmp.renameSync(_indexFile.path);
      return const Success(null);
    } on Object catch (error) {
      return Failure('skill.write-failed', '技能索引写入失败：$error');
    }
  }

  List<SkillManifest> _byStatus(SkillStatus status) => [
    for (final skill in _index.values)
      if (skill.status == status) skill,
  ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  static String _clip(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max)}…';
}

/// SKILL.md = YAML frontmatter（本实现只需 key: value 与 [a, b] 列表）
/// + Markdown 正文。不引入 yaml 依赖，解析器保持最小子集。
String encodeSkillMd(SkillManifest skill) {
  final buffer = StringBuffer('---\n')
    ..writeln('name: ${skill.name}')
    ..writeln('description: ${skill.description}')
    ..writeln('triggers: ${skill.triggers}')
    ..writeln('kind: ${skill.kind.name}')
    ..writeln('version: ${skill.version}')
    ..writeln('source: ${skill.source}');
  if (skill.originReflectionIds.isNotEmpty) {
    buffer.writeln(
      'origin_reflection_ids: [${skill.originReflectionIds.join(', ')}]',
    );
  }
  buffer.writeln('created_at: ${skill.createdAt.toIso8601String()}');
  if (skill.approvedAt != null) {
    buffer.writeln('approved_at: ${skill.approvedAt!.toIso8601String()}');
  }
  if (skill.archivedAt != null) {
    buffer.writeln('archived_at: ${skill.archivedAt!.toIso8601String()}');
  }
  return '$buffer---\n\n${skill.body.trim()}\n';
}

/// 解析 SKILL.md；frontmatter 缺关键字段返回 null（坏文件跳过不阻塞装载）。
SkillManifest? parseSkillMd(String raw) {
  final lines = const LineSplitter().convert(raw);
  if (lines.isEmpty || lines[0].trim() != '---') return null;
  final fields = <String, String>{};
  var bodyStart = lines.length;
  for (var index = 1; index < lines.length; index++) {
    final line = lines[index];
    if (line.trim() == '---') {
      bodyStart = index + 1;
      break;
    }
    final separator = line.indexOf(':');
    if (separator <= 0) continue;
    final key = line.substring(0, separator).trim();
    // 值里允许出现冒号（如描述文本），只按第一个冒号切分。
    fields[key] = line.substring(separator + 1).trim();
  }
  final name = fields['name'] ?? '';
  final description = fields['description'] ?? '';
  if (name.isEmpty || description.isEmpty) return null;
  final body = lines.skip(bodyStart).join('\n').trim();
  // frontmatter 是唯一事实：三态由 approved_at/archived_at 恢复。
  return SkillManifest(
    name: name,
    description: description,
    triggers: fields['triggers'] ?? '',
    body: body,
    kind: switch (fields['kind']) {
      'preference' => SkillKind.preference,
      'fact' => SkillKind.fact,
      _ => SkillKind.procedural,
    },
    version: int.tryParse(fields['version'] ?? '') ?? 1,
    source: fields['source'] ?? 'task-reflection',
    originReflectionIds: _parseList(fields['origin_reflection_ids']),
    status: fields['archived_at'] != null
        ? SkillStatus.archived
        : fields['approved_at'] != null
        ? SkillStatus.active
        : SkillStatus.pending,
    createdAt:
        DateTime.tryParse(fields['created_at'] ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    approvedAt: DateTime.tryParse(fields['approved_at'] ?? ''),
    archivedAt: DateTime.tryParse(fields['archived_at'] ?? ''),
  );
}

/// 解析 `[a, b, c]` 形式的行内列表。
List<String> _parseList(String? raw) {
  if (raw == null) return const [];
  final text = raw.trim();
  if (!text.startsWith('[') || !text.endsWith(']')) return const [];
  return [
    for (final item in text.substring(1, text.length - 1).split(','))
      if (item.trim().isNotEmpty) item.trim(),
  ];
}
