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

  /// 任务终态：记录结果摘要，供后续复盘；不直接生成准则。
  void recordStatus(StatusSnapshot? snapshot) {
    if (snapshot == null || !snapshot.isTerminal) return;
    _reflections.record(
      ReflectionEntry(
        id: ReflectionEntry.newId(_clock()),
        at: _clock(),
        kind: ReflectionKind.task,
        outcome: snapshot.state == AssistantStatus.success
            ? 'success'
            : 'failure',
        summary: snapshot.text.trim().isEmpty
            ? snapshot.state.name
            : snapshot.text.trim(),
        source: snapshot.source,
        taskId: snapshot.taskId ?? '',
        evidence: ['status:${snapshot.state.name}'],
      ),
    );
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
