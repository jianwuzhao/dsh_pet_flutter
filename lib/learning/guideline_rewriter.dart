/// 准则措辞优化器（P1-5 OPRO）：为低效准则生成 2 个候选措辞。
///
/// 只产出候选，不直接生效；候选交给 GuidelineStore 开影子试验，
/// 影子比较胜出且用户确认后才替换。措辞是“同一件事换种说法”，
/// 越权表述（身份/隐私/权限）与语义漂移都在护栏里挡掉。
library;

import 'dart:convert';

import '../ai/llm_provider.dart';
import '../ai/thinking_tier.dart';
import '../core/result.dart';
import 'guideline_store.dart';
import 'llm_reflection_synthesizer.dart';

class GuidelineRewriter {
  const GuidelineRewriter(this.provider);

  final LlmProvider provider;

  /// 最多取 2 个候选：影子试验每臂 5 次注入，臂多了试验周期拉太长。
  static const int maxCandidates = 2;

  /// 候选长度上限：与准则 content 的复盘上限同额（80 字）。
  static const int maxCandidateChars = 80;

  /// 生成候选措辞；任何失败都折叠成空列表——影子优化是纯增益路径，
  /// 不该让反馈链路背上错误处理负担。
  Future<List<String>> rewrite(Guideline guideline) async {
    if (!provider.supportsReply) return const <String>[];
    final result = await provider.chat(
      LlmRequest(
        system: _systemPrompt,
        messages: [LlmMessage.user(_inputFor(guideline))],
        thinkingTier: ThinkingTier.deep,
      ),
    );
    if (result is Failure<LlmReply>) return const <String>[];
    return _parse((result as Success<LlmReply>).value.content, guideline);
  }

  static String _inputFor(Guideline guideline) => [
    '标题：${guideline.title}',
    '正文：${guideline.content}',
    if (guideline.trigger.trim().isNotEmpty) '触发关键词：${guideline.trigger}',
    '注入 ${guideline.useCount} 次，采纳 ${guideline.acceptedAfterUse} 次、'
        '纠正 ${guideline.correctedAfterUse} 次',
  ].join('\n');

  static const String _systemPrompt = '''
你是措辞优化助手。下面是一条被注入对话的经验准则，它的措辞效果不佳（注入多次仍常被纠正）。
请为它写 2 个意思完全相同、但表达更有效的中文候选措辞。
只输出一个 JSON 对象，不要解释、不要 Markdown 代码围栏：
{"candidates":["候选措辞一","候选措辞二"]}

规则：
1. 只改措辞，不改语义边界：适用场景、建议方向、触发条件都不能变。
2. 每条不超过 80 字，是一条可直接注入的完整句子。
3. 不涉及身份、隐私、权限、密钥、打扰上限的修改。
4. 两个候选都要明显区别于原文和彼此。
''';

  /// 严格解析 + 护栏：空/越权/与原文相同/互相重复的候选逐条丢弃，
  /// 剩下少于 2 条也能用（影子试验支持单候选）。
  static List<String> _parse(String raw, Guideline guideline) {
    try {
      final cleaned = LlmReflectionSynthesizer.stripFence(raw);
      final start = cleaned.indexOf('{');
      final end = cleaned.lastIndexOf('}');
      if (start < 0 || end <= start) return const <String>[];
      final decoded = jsonDecode(cleaned.substring(start, end + 1));
      if (decoded is! Map) return const <String>[];
      final list = decoded['candidates'];
      if (list is! List) return const <String>[];

      final original = guideline.content.trim();
      final accepted = <String>[];
      for (final item in list) {
        if (item is! String) continue;
        var text = item.trim();
        if (text.isEmpty || text == original) continue;
        if (LlmReflectionSynthesizer.unsafePattern.hasMatch(text)) continue;
        // 超长不硬截：截断的句子容易半途变义，整条丢弃更稳。
        if (text.length > maxCandidateChars) continue;
        if (accepted.any((existing) => existing == text)) continue;
        accepted.add(text);
        if (accepted.length >= maxCandidates) break;
      }
      return List.unmodifiable(accepted);
    } on Object {
      return const <String>[];
    }
  }
}
