/// 进化引擎：把“发生过什么”沉淀为反思，再把重复出现的纠正提炼成准则提案。
///
/// 纠正重复用确定性聚类；任务经验可由上层注入模型合成。无论哪种来源，
/// 都只生成待确认准则，用户接受后才生效，避免不可解释的自动改写。
library;

import '../core/result.dart';
import '../features/linkage/status/assistant_event.dart';
import 'guideline_store.dart';
import 'llm_reflection_synthesizer.dart';
import 'reflection_store.dart';

class EvolutionEngine {
  EvolutionEngine({
    required ReflectionStore reflections,
    required GuidelineStore guidelines,
    DateTime Function()? clock,
  }) : _reflections = reflections,
       _guidelines = guidelines,
       _clock = clock ?? DateTime.now;

  final ReflectionStore _reflections;
  final GuidelineStore _guidelines;
  final DateTime Function() _clock;

  ReflectionStore get reflections => _reflections;
  GuidelineStore get guidelines => _guidelines;

  int get reflectionCount => _reflections.load().length;

  /// intent 截断上限：dispatch 原文可能很长，反思里只需要“当时想做什么”。
  static const int maxIntentChars = 80;

  /// 任务终态：记录结果摘要，供后续复盘；不直接生成准则。
  ///
  /// [intent] 是触发这次任务的 dispatch 原文（截断 80 字符）：
  /// 没有它，后续复盘只能看到“失败了”，猜不出“当时想干什么”。
  void recordStatus(StatusSnapshot? snapshot, {String intent = ''}) {
    if (snapshot == null || !snapshot.isTerminal) return;
    final isSuccess = snapshot.state == AssistantStatus.success;
    _reflections.record(
      ReflectionEntry(
        id: ReflectionEntry.newId(_clock()),
        at: _clock(),
        kind: ReflectionKind.task,
        outcome: isSuccess ? 'success' : 'failure',
        summary: snapshot.text.trim().isEmpty
            ? snapshot.state.name
            : snapshot.text.trim(),
        source: snapshot.source,
        taskId: snapshot.taskId ?? '',
        intent: _clipIntent(intent),
        // 根因初值只到“哪个通道、什么终态”这一层：把猜测留给复盘，
        // 但先占住字段位，保证后续复盘是“修正”而不是“补写”。
        rootCause: isSuccess
            ? ''
            : '${snapshot.source} 通道任务失败（${snapshot.state.name}），根因待复盘',
        // 任务终态没有用户参与判定：成功是系统自报，失败根因未验证。
        verification: isSuccess ? 'auto-observed' : 'unverified',
        evidence: ['status:${snapshot.state.name}'],
      ),
    );
  }

  static String _clipIntent(String text) {
    final trimmed = text.trim();
    if (trimmed.length <= maxIntentChars) return trimmed;
    return '${trimmed.substring(0, maxIntentChars)}…';
  }

  /// 用户采纳回复：正样本，用于后续判断某条准则是否有效。
  void recordAccept() {
    _reflections.record(
      ReflectionEntry(
        id: ReflectionEntry.newId(_clock()),
        at: _clock(),
        kind: ReflectionKind.feedback,
        outcome: 'positive',
        summary: '用户采纳回复',
        source: 'user',
        verification: 'user-accepted',
        evidence: ['feedback:accepted'],
      ),
    );
  }

  /// 用户拒绝并附纠正：先记反思；同一纠正 30 天内出现 ≥2 次，
  /// 生成一条“始终适用”的准则提案，等用户确认。
  void recordCorrection(String correction) {
    final text = correction.trim();
    if (text.isEmpty) return;
    _reflections.record(
      ReflectionEntry(
        id: ReflectionEntry.newId(_clock()),
        at: _clock(),
        kind: ReflectionKind.correction,
        outcome: 'negative',
        summary: text,
        source: 'user',
        // 用户指出的“哪里不对”本身就是根因的最好初值，
        // 后续复盘只需要在此基础上细化，而不是从零猜。
        rootCause: text,
        // 纠正来自用户亲眼观察：结果验证方式记 user-observed。
        verification: 'user-observed',
        evidence: ['feedback:corrected'],
      ),
    );
    final count = _reflections.countSimilar(
      kind: ReflectionKind.correction,
      summary: text,
      now: _clock(),
    );
    if (count < 2) return;
    _guidelines.propose(
      Guideline(
        id: 'g${_clock().microsecondsSinceEpoch}',
        title: '用户反复纠正：${_shorten(text)}',
        content: '用户多次纠正「$text」；回应时避免重复这个问题。',
        source: 'correction',
        evidence: ['correction:$text', 'occurrences:$count'],
        createdAt: _clock(),
      ),
    );
  }

  /// 把模型提炼的任务经验转成待确认准则；返回新增提案数。
  int proposeTaskLessons(List<TaskLessonDraft> drafts) {
    var added = 0;
    for (final draft in drafts) {
      final before = _guidelines.pending.length;
      final result = _guidelines.propose(
        Guideline(
          id: 'g${_clock().microsecondsSinceEpoch}-${draft.hashCode}',
          title: draft.title,
          content: draft.content,
          trigger: draft.trigger,
          source: 'task',
          evidence: ['confidence:${draft.confidence.toStringAsFixed(2)}'],
          createdAt: _clock(),
        ),
      );
      if (result is Success<void> && _guidelines.pending.length > before) {
        added += 1;
      }
    }
    return added;
  }

  static String _shorten(String text) {
    final trimmed = text.trim();
    return trimmed.length <= 24 ? trimmed : '${trimmed.substring(0, 24)}…';
  }
}
