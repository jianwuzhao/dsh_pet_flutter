/// 记忆抽取：把对话文本变成记忆条目（计划 4.4）。
///
/// 两条路径，信任级别不同：
/// - 规则抽取：称呼/回避/作息这类确定性模式，直写 active；
/// - LLM 候选：模型在回复正文里用 `[[memory:kind|内容]]` 标记自荐，
///   解析为 pending 提案，用户接受才生效——不做无确认的自动事实写入。
/// 规则宁缺勿滥：拿不准的模式不写，错误记忆比没有记忆更伤信任。
library;

import '../memory/memory_entry.dart';

class MemoryExtractor {
  const MemoryExtractor();

  /// 规则抽取（用户文本 → active 记忆）；无匹配返回空表。
  List<MemoryEntry> extractRules(String text, {required DateTime now}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const [];
    return [
      ..._extractAddress(trimmed, now),
      ..._extractAvoidedTopics(trimmed, now),
      ..._extractRoutine(trimmed, now),
    ];
  }

  /// LLM 标记解析：返回（pending 候选, 剥掉标记后的正文）。
  (List<MemoryEntry> candidates, String content) extractFromReply(
    String reply, {
    required DateTime now,
  }) {
    final candidates = <MemoryEntry>[];
    var index = 0;
    final buffer = StringBuffer();
    while (true) {
      // Dart 正则没有带起点的 firstMatch，用 allMatches(reply, start) 代替。
      final match = _memoryTag.allMatches(reply, index).firstOrNull;
      if (match == null) break;
      buffer.write(reply.substring(index, match.start));
      final kind = _kindOfTag(match.group(1));
      final content = (match.group(2) ?? '').trim();
      if (kind != null && content.isNotEmpty) {
        candidates.add(
          MemoryEntry(
            id: MemoryEntry.newId(now),
            kind: kind,
            content: content,
            createdAt: now,
            source: 'llm',
            status: MemoryStatus.pending,
            confidence: 0.5,
            updatedAt: now,
          ),
        );
      }
      index = match.end;
    }
    buffer.write(reply.substring(index));
    return (candidates, buffer.toString().trim());
  }

  // ---- 规则一：称呼偏好 ----
  // 要求“以后/都/请/记得”等明确意愿语境，避免“叫我妈买菜”这类误判。
  static final RegExp _addressPattern = RegExp(
    r'(?:以后都?|都|请|记得|以后请)叫我([^，。！？!?,,\n]{1,12})',
  );
  static final RegExp _addressLeadingQuote = RegExp(r"^[\x22“”'「『]+");
  static final RegExp _addressTrailingQuote = RegExp(r"[\x22“”'」』]+$");
  static final RegExp _addressTrailing = RegExp(r'[吧了哦呀啊~～\s]+$');

  List<MemoryEntry> _extractAddress(String text, DateTime now) {
    final match = _addressPattern.firstMatch(text);
    if (match == null) return const [];
    var name = (match.group(1) ?? '').trim();
    // 先剥语气词再剥引号：顺序反了会把“老李”后紧贴的引号留下来。
    name = name
        .replaceFirst(_addressTrailing, '')
        .replaceFirst(_addressLeadingQuote, '')
        .replaceFirst(_addressTrailingQuote, '');
    if (name.isEmpty) return const [];
    return [
      MemoryEntry(
        id: MemoryEntry.newId(now),
        kind: MemoryKind.preference,
        subject: 'address',
        content: '称呼偏好：$name',
        createdAt: now,
        source: 'rule',
        confidence: 0.9,
        updatedAt: now,
      ),
    ];
  }

  // ---- 规则二：回避话题（“别提X / 不想聊X”，两分支各占一个捕获组） ----
  List<MemoryEntry> _extractAvoidedTopics(String text, DateTime now) {
    return [
      for (final match in _avoidedPattern.allMatches(text))
        if (((match.group(1) ?? match.group(2)) ?? '').trim().isNotEmpty)
          MemoryEntry(
            id: MemoryEntry.newId(now),
            kind: MemoryKind.preference,
            subject:
                'avoidedTopic:${(match.group(1) ?? match.group(2))!.trim()}',
            content: '回避话题：${(match.group(1) ?? match.group(2))!.trim()}',
            createdAt: now,
            source: 'rule',
            confidence: 0.85,
            updatedAt: now,
          ),
    ];
  }

  static final RegExp _avoidedPattern = RegExp(
    r'(?:别|不要|不想)(?:再)?提(?:起|到|及)?([^，。！？!?,,\n]{1,20})'
    r'|(?:别|不要|不想)聊([^，。！？!?,,\n]{1,20})',
  );

  // ---- 规则三：作息（显式“X点睡/起床”才收，模糊表述不猜） ----
  List<MemoryEntry> _extractRoutine(String text, DateTime now) {
    final match = _routinePattern.firstMatch(text);
    if (match == null) return const [];
    final hour = int.tryParse(match.group(1) ?? '');
    if (hour == null || hour < 0 || hour > 24) return const [];
    final half = (match.group(2) ?? '').isNotEmpty ? '半' : '';
    final action = (match.group(4) ?? '').isNotEmpty ? '起床' : '睡';
    return [
      MemoryEntry(
        id: MemoryEntry.newId(now),
        kind: MemoryKind.fact,
        subject: 'routine',
        content: '作息：约 $hour 点$half$action',
        createdAt: now,
        source: 'rule',
        confidence: 0.8,
        updatedAt: now,
      ),
    ];
  }

  // 分组：1=小时 2=半点 3=睡 4=起床。
  static final RegExp _routinePattern = RegExp(
    r'(\d{1,2})点(半)?(?:左右|多|才|就)?(?:去|要|得)?(?:(睡)|(起床))',
  );

  /// kind 放宽到任意单词：未知 kind 的标记同样要从正文剥掉（协议噪音
  /// 不能漏给用户看），只是不生成候选。
  static final RegExp _memoryTag = RegExp(
    r'\[\[memory:([a-z-]+)\|([^\[\]|]{1,80})\]\]',
  );

  static MemoryKind? _kindOfTag(String? raw) => switch (raw) {
    'preference' => MemoryKind.preference,
    'fact' => MemoryKind.fact,
    'task' => MemoryKind.task,
    'episode' => MemoryKind.episode,
    _ => null,
  };
}
