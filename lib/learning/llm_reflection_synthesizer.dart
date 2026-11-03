/// 任务反思合成器：让模型把最近的任务终态反思提炼成 1–3 条经验草案。
///
/// 只产出草案，不直接生效；草案由 EvolutionEngine 转成待确认准则。
/// 输出走严格 JSON 解析，异常返回结构化 Failure，绝不把模型散文当准则。
library;

import 'dart:convert';

import '../ai/llm_provider.dart';
import '../ai/thinking_tier.dart';
import '../core/result.dart';
import 'reflection_store.dart';

class TaskLessonDraft {
  const TaskLessonDraft({
    required this.title,
    required this.content,
    this.trigger = '',
    this.confidence = 0.5,
    this.isSkill = false,
    this.name = '',
    this.steps = '',
  });

  final String title;
  final String content;
  final String trigger;
  final double confidence;

  /// true = 程序性做法（多步“怎么做”），走技能草案通道；
  /// false = 一句话倾向（“别做什么”），走准则提案通道。
  final bool isSkill;

  /// 技能 id（kebab-case）：isSkill 时必填，非法即丢弃整条。
  final String name;

  /// 技能正文（≤300 字做法步骤）：isSkill 时必填。
  final String steps;
}

class LlmReflectionSynthesizer {
  const LlmReflectionSynthesizer(this.provider);

  final LlmProvider provider;

  /// 单次最多 3 条：避免一次复盘把待确认队列刷爆。
  static const int maxLessons = 3;

  /// 发给模型的输入上限（字符）：超长时保留最近的反思，旧的截掉。
  /// 既是成本闸，也避免超长 prompt 拖慢总结。
  static const int maxInputChars = 4000;

  Future<Result<List<TaskLessonDraft>>> synthesize(
    List<ReflectionEntry> reflections,
  ) async {
    if (reflections.isEmpty) return const Success(<TaskLessonDraft>[]);
    if (!provider.supportsReply) {
      return Failure('reflection.forward-only', '当前 provider 只支持转发，不能做反思总结');
    }
    final input = _buildInput(reflections);
    final result = await provider.chat(
      LlmRequest(
        system: _systemPrompt,
        messages: [LlmMessage.user(input)],
        thinkingTier: ThinkingTier.fast,
      ),
    );
    switch (result) {
      case Failure(:final code, :final reason):
        return Failure(code, reason);
      case Success(value: final reply):
        return _parse(reply.content, input);
    }
  }

  /// 拼装模型输入：outcome/summary 之外尽量带上 intent/rootCause/verification，
  /// 让模型知道“当时想做什么、为什么失败、结果怎么验证的”。
  static String _buildInput(List<ReflectionEntry> reflections) {
    final buffer = StringBuffer('最近的任务终态：\n');
    for (final item in reflections) {
      buffer
        ..write('- outcome=${item.outcome}')
        ..write(' source=${item.source}')
        ..write(' summary=${item.summary}');
      if (item.intent.isNotEmpty) buffer.write(' intent=${item.intent}');
      if (item.rootCause.isNotEmpty) {
        buffer.write(' rootCause=${item.rootCause}');
      }
      if (item.verification.isNotEmpty) {
        buffer.write(' verification=${item.verification}');
      }
      buffer.writeln();
    }
    var text = buffer.toString().trim();
    if (text.length > maxInputChars) {
      // 反思按时间追加，尾部是最近的：保留尾部，砍掉最旧的。
      text = text.substring(text.length - maxInputChars);
    }
    return text;
  }

  static const String _systemPrompt = '''
你是任务复盘助手。请从用户提供的任务终态反思中提炼 1–3 条可复用经验。
只输出一个 JSON 对象，不要解释、不要 Markdown 代码围栏：
{"lessons":[{"kind":"guideline","title":"不超过24字","content":"不超过80字","trigger":"关键词|关键词","confidence":0.0}]}
或（仅当经验是多步骤的“怎么做”时）：
{"lessons":[{"kind":"skill","name":"kebab-case-id","title":"不超过24字","content":"不超过80字","trigger":"关键词|关键词","steps":"不超过300字的做法步骤","confidence":0.0}]}

规则：
1. 只依据输入中真实出现的结果，不编造事实。
2. guideline 是“遇到什么情况，应该怎么做”的一句话倾向；skill 是可复用多次的多步做法——只在步骤确实多于一步时才用 skill。
3. 不涉及身份、隐私、权限、密钥、打扰上限的修改。
4. 没有可复用经验时返回 {"lessons":[]}。
5. confidence ∈ [0,1]，证据弱时给低分。
''';

  Result<List<TaskLessonDraft>> _parse(String raw, String input) {
    try {
      final cleaned = _stripFence(raw);
      final start = cleaned.indexOf('{');
      final end = cleaned.lastIndexOf('}');
      if (start < 0 || end <= start) {
        return const Failure('reflection.parse', '模型输出不是 JSON 对象');
      }
      final decoded = jsonDecode(cleaned.substring(start, end + 1));
      if (decoded is! Map) {
        return const Failure('reflection.parse', '模型输出不是 JSON 对象');
      }
      final list = decoded['lessons'];
      if (list is! List) {
        return const Failure('reflection.parse', '模型输出缺少 lessons 数组');
      }
      final lessons = <TaskLessonDraft>[];
      for (final item in list) {
        if (item is! Map) continue;
        final title = (item['title'] as String? ?? '').trim();
        final content = (item['content'] as String? ?? '').trim();
        if (title.isEmpty || content.isEmpty) continue;
        if (unsafePattern.hasMatch(title) ||
            unsafePattern.hasMatch(content)) {
          continue;
        }
        final trigger = _shorten((item['trigger'] as String? ?? '').trim(), 40);
        final isSkill = (item['kind'] as String? ?? '') == 'skill';
        final steps = _shorten((item['steps'] as String? ?? '').trim(), 300);
        final name = (item['name'] as String? ?? '').trim();
        // 技能条目三重门槛：合法 id、非空步骤、步骤也过越权过滤。
        // 缺任何一项整条丢弃——技能是可复用多次的做法，宁缺毋滥。
        if (isSkill) {
          if (!RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$').hasMatch(name)) continue;
          if (steps.isEmpty || unsafePattern.hasMatch(steps)) continue;
        }
        // 事实一致性：经验必须与输入反思有交集（正文共现或 trigger 命中），
        // 挡住“正确但与本次任务无关的废话”。
        if (!_groundedIn(
          isSkill ? '$content$steps' : content,
          trigger,
          input,
        )) {
          continue;
        }
        lessons.add(
          TaskLessonDraft(
            title: _shorten(title, 24),
            content: _shorten(content, 80),
            trigger: trigger,
            isSkill: isSkill,
            name: name,
            steps: steps,
            confidence: ((item['confidence'] as num?)?.toDouble() ?? 0.5).clamp(
              0.0,
              1.0,
            ),
          ),
        );
        if (lessons.length >= maxLessons) break;
      }
      return Success(lessons);
    } on FormatException catch (error) {
      return Failure('reflection.parse', 'JSON 解析失败：${error.message}');
    } on Object catch (error) {
      return Failure('reflection.parse', '反思总结解析失败：$error');
    }
  }

  /// 经验是否“长在”输入上：正文与输入共享至少一个字符 bigram，
  /// 或 trigger 的任一关键词出现在输入里。
  static bool _groundedIn(String content, String trigger, String input) {
    final inputBigrams = _bigrams(_normalize(input));
    if (_bigrams(_normalize(content)).any(inputBigrams.contains)) return true;
    final keywords = trigger
        .split(RegExp(r'[|,，、]'))
        .map((word) => word.trim().toLowerCase())
        .where((word) => word.length >= 2);
    final text = input.toLowerCase();
    return keywords.any(text.contains);
  }

  static String _normalize(String text) => text.toLowerCase().replaceAll(
    RegExp(r'[\s，。！？!?、,.：:；;（）()\[\]【】“”「」]'),
    '',
  );

  static Set<String> _bigrams(String text) => {
    for (var index = 0; index + 1 < text.length; index++)
      text.substring(index, index + 2),
  };

  static String _stripFence(String raw) {
    var text = raw.trim();
    if (text.startsWith('```')) {
      text = text.replaceFirst(RegExp(r'^```(?:json)?\s*'), '');
      if (text.endsWith('```')) {
        text = text.substring(0, text.length - 3);
      }
    }
    return text.trim();
  }

  static String _shorten(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max)}…';

  /// 只挡明显的越权/泄密表述；正常经验不会被误杀。
  /// 公开给其它学习组件复用（如纠正解析器），保持同一套越权判定口径。
  static final RegExp unsafePattern = RegExp(
    r'忽略(之前|以上)|系统提示|system prompt|泄露|密钥|密码|token',
    caseSensitive: false,
  );
}
