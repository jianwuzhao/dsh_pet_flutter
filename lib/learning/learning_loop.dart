/// 学习闭环编排：采集 → 清洗统计 → 门禁 → 提案 → 应用 → 监控 → 自动回滚（计划 4.5）。
///
/// 首期只做一、二级学习：记忆候选与策略参数。
/// 用户对提案的“接受/拒绝”、对回复的“采纳/重说”、对主动关心的“提前关闭”
/// 都只是取舍行为——没有 👍/👎 评分，沉默（自然过期）记中性不计样本。
library;

import 'dart:async';

import '../core/result.dart';
import '../persona/expression/expression_layer.dart';
import '../persona/memory/memory_store.dart';
import 'correction_parser.dart';
import 'eval_gate.dart';
import 'feedback_collector.dart';
import 'guideline_store.dart';
import 'policy_store.dart';

/// 新策略应用后的灰度观察窗与自动回滚阈值。
const Duration autoRollbackWindow = Duration(hours: 24);
const int autoRollbackRejects = 2;

class LearningLoop {
  LearningLoop({
    required FeedbackCollector collector,
    required PolicyStore policy,
    required ExpressionHost host,
    EvalGate gate = const EvalGate(),
    CorrectionParser? correctionParser,
    GuidelineStore? guidelines,
    DateTime Function()? clock,
  }) : _collector = collector,
       _policy = policy,
       _host = host,
       _gate = gate,
       _correctionParser = correctionParser,
       _guidelines = guidelines,
       _clock = clock ?? DateTime.now;

  final FeedbackCollector _collector;
  final PolicyStore _policy;
  final ExpressionHost _host;
  final EvalGate _gate;

  /// 二级（LLM）纠正解析器：null = 只有规则解析（现状行为）。
  final CorrectionParser? _correctionParser;

  /// 经验准则（P1-2 有效性回路）：回复采纳/纠正时反查注入计数。
  /// 可选：内核未启用准则时不回填，行为与现状一致。
  final GuidelineStore? _guidelines;

  final DateTime Function() _clock;

  /// 触发 LLM 二级解析的最低近期纠正次数：第一次纠正先不花调用，
  /// 重复纠正说明用户确实在意这件事，才值得让模型补一次归类。
  static const int llmParseMinCorrections = 2;

  static int _sequence = 0;

  PolicyStore get policy => _policy;
  FeedbackCollector get collector => _collector;

  /// 记忆提案被接受：生效 + 记正样本。
  Result<void> acceptMemoryProposal(MemoryStore memory, String id) {
    final result = memory.confirm(id);
    if (result is Failure<void>) return result;
    return _collector.record(
      FeedbackVerdict.accepted,
      target: '$feedbackTargetMemory:$id',
    );
  }

  /// 记忆提案被拒绝：丢弃 + 记负样本；附纠正时再尝试解析为策略候选。
  Result<void> rejectMemoryProposal(
    MemoryStore memory,
    String id, {
    String correction = '',
  }) {
    final result = memory.reject(id);
    if (result is Failure<void>) return result;
    return _recordNegative(feedbackTargetMemory, id, correction);
  }

  /// 回复被采纳：用户把建议落到了实处。
  ///
  /// 同时回填准则有效性计数（P1-2）：24h 内注入过的 active 准则
  /// acceptedAfterUse +1；只统计不判断，停用提案由 store 内部生成。
  Result<void> acceptReply() {
    final result = _collector.record(
      FeedbackVerdict.accepted,
      target: '$feedbackTargetReply:${_entryId()}',
    );
    if (result is Success<void>) {
      _guidelines?.recordInjectionOutcome(accepted: true);
    }
    return result;
  }

  /// 回复被拒绝（重说）：记负样本；附纠正时尝试生成策略提案。
  Result<void> rejectReply({String correction = ''}) {
    final result = _recordNegative(feedbackTargetReply, _entryId(), correction);
    if (result is Success<void>) {
      _guidelines?.recordInjectionOutcome(accepted: false);
    }
    return result;
  }

  /// 主动关心气泡被提前关闭（自然过期不算）。
  Result<void> dismissCare() => _collector.record(
    FeedbackVerdict.rejected,
    target: '$feedbackTargetCare:${_entryId()}',
  );

  /// 手动回滚（设置页）：只做版本切换，不产生反馈样本。
  Result<void> rollback() => _policy.rollback();

  Result<void> rollbackTo(int version) => _policy.rollbackTo(version);

  /// 接受策略提案：应用并记正样本。
  Result<void> acceptPolicyProposal(String id) {
    final field = _proposalField(id);
    final result = _policy.acceptProposal(id);
    if (result is Failure<void>) return result;
    return _collector.record(
      FeedbackVerdict.accepted,
      target: '$feedbackTargetPolicy:$field',
    );
  }

  /// 拒绝策略提案：丢弃并记负样本。
  Result<void> rejectPolicyProposal(String id) {
    final field = _proposalField(id);
    final result = _policy.rejectProposal(id);
    if (result is Failure<void>) return result;
    return _collector.record(
      FeedbackVerdict.rejected,
      target: '$feedbackTargetPolicy:$field',
    );
  }

  /// 反馈驱动的候选提案：纠正语句 → 策略字段 → 过门禁 → 入待确认队列。
  /// 返回 null 表示没有可提案的增量（纠正语句不含策略线索）。
  PolicyProposal? proposeFromCorrection(String correction) {
    final candidate = parseCorrection(correction);
    if (candidate == null) return null;
    return _proposeCandidate(candidate.$1, candidate.$2, correction);
  }

  /// 规则未命中后的二级解析：近期同类纠正达到阈值才花这一次 LLM 调用。
  /// 异步执行，不阻塞反馈链路；解析不出就保持现状（不提案）。
  Future<void> _maybeParseWithLlm(String correction) async {
    final parser = _correctionParser;
    if (parser == null) return;
    final now = _clock();
    // 只统计落在 reply: 目标上的纠正：规则命中的会落在 policy: 字段目标，
    // 这里要看的正是“规则解析不出来的那类纠正”的重复度。
    final recent = _collector.count(
      FeedbackVerdict.corrected,
      target: 'reply',
      window: autoRollbackWindow,
      now: now,
    );
    if (recent < llmParseMinCorrections) return;
    final parsed = await parser.parse(correction);
    if (parsed == null) return;
    // 解析结果仍要过同一道门禁：白名单之外 EvalGate 兜底。
    _proposeCandidate(parsed.field, parsed.value, correction, byDetail: true);
  }

  /// 候选落队：门禁 → 提案。规则与 LLM 两条路径共用。
  ///
  /// [byDetail] 为 true 时（LLM 路径），同向样本除字段目标事件外
  /// 还累计“同文本纠正”事件——这类纠正规则解析不出来，事件只能落在
  /// reply: 目标上，不补这个口径它们永远凑不齐门禁的同向样本。
  PolicyProposal? _proposeCandidate(
    String field,
    String value,
    String correction, {
    bool byDetail = false,
  }) {
    final now = _clock();
    final supporting = byDetail
        ? _countSupportingByDetail(field, correction, now)
        : _collector.count(
            FeedbackVerdict.corrected,
            target: '$feedbackTargetPolicy:$field',
            window: autoRollbackWindow,
            now: now,
          );
    final opposing = _collector.count(
      FeedbackVerdict.accepted,
      target: '$feedbackTargetPolicy:$field',
      window: autoRollbackWindow,
      now: now,
    );
    final verdict = _gate.reviewPolicyChange(
      field: field,
      value: value,
      supporting: supporting,
      opposing: opposing,
    );
    if (!verdict.approved) return null;

    final proposal = PolicyProposal(
      id: 'p${now.microsecondsSinceEpoch}-${_sequence++}',
      field: field,
      value: value,
      reason: '你提到「${correction.trim()}」，想按这个调整表达方式',
      createdAt: now,
    );
    _policy.propose(proposal);
    return proposal;
  }

  /// LLM 路径的同向样本：字段目标事件 + 同文本纠正事件（窗口内）。
  /// 两类事件天然不重叠：规则命中时事件落在字段目标上且不会再走 LLM。
  int _countSupportingByDetail(String field, String detail, DateTime now) {
    final windowStart = now.subtract(autoRollbackWindow);
    final normalized = detail.trim();
    final sameDetail = _collector
        .load()
        .where(
          (event) =>
              event.verdict == FeedbackVerdict.corrected &&
              event.at.isAfter(windowStart) &&
              event.detail.trim() == normalized,
        )
        .length;
    return _collector.count(
          FeedbackVerdict.corrected,
          target: '$feedbackTargetPolicy:$field',
          window: autoRollbackWindow,
          now: now,
        ) +
        sameDetail;
  }

  /// 自动回滚监控：新版本应用后 24h 内累计 ≥2 次拒绝/纠正 → 回滚上一版。
  /// 返回 true 表示真的回滚了（调用方一般不需要额外处理，气泡在此发出）。
  bool checkAutoRollback() {
    final appliedAt = _policy.appliedAt;
    if (_policy.version <= 1) return false;
    final now = _clock();
    final elapsed = now.difference(appliedAt);
    if (elapsed.isNegative || elapsed > autoRollbackWindow) return false;

    final negatives = _collector
        .load()
        .where(
          (event) =>
              event.at.isAfter(appliedAt) &&
              (event.target.startsWith('$feedbackTargetReply:') ||
                  event.target.startsWith('$feedbackTargetPolicy:')) &&
              (event.verdict == FeedbackVerdict.rejected ||
                  event.verdict == FeedbackVerdict.corrected),
        )
        .length;
    if (negatives < autoRollbackRejects) return false;

    final previous = _policy.version - 1;
    switch (_policy.rollback()) {
      case Success():
        _host.showBubble('新策略最近老不合你意，已经回滚到 v$previous');
        return true;
      case Failure():
        return false;
    }
  }

  /// 纠正语句规则解析：只有当用户说清方向时才产出候选，模糊表述不猜。
  /// 返回（字段, 目标值）。
  static (String, String)? parseCorrection(String correction) {
    final text = correction.trim();
    if (text.isEmpty) return null;
    // 顺序敏感：“别用表格”必须排在“用表格”前面。
    if (_containsAny(text, ['别用表格', '不要表格', '不用表格'])) {
      return ('tablePreference', 'avoid');
    }
    if (_containsAny(text, ['用表格', '表格更清楚'])) {
      return ('tablePreference', 'allow');
    }
    if (_containsAny(text, ['别用表情', '不要表情', '别发emoji', '别用emoji'])) {
      return ('emojiUsage', 'none');
    }
    if (_containsAny(text, ['别烦', '少关心', '安静点', '别打扰'])) {
      return ('careTone', 'quiet');
    }
    if (_containsAny(text, ['太长', '啰嗦', '简短', '短一点', '精简'])) {
      return ('replyLength', 'brief');
    }
    if (_containsAny(text, ['详细', '具体点', '多说点'])) {
      return ('replyLength', 'detailed');
    }
    return null;
  }

  /// 记一条负样本：纯拒绝用 rejected，带纠正用 corrected（正文进 detail）。
  /// 纠正能解析出策略字段时，target 直接落在该字段上——门禁按字段统计同向样本。
  Result<void> _recordNegative(
    String targetPrefix,
    String id,
    String correction,
  ) {
    final detail = correction.trim();
    if (detail.isEmpty) {
      final result = _collector.record(
        FeedbackVerdict.rejected,
        target: '$targetPrefix:$id',
      );
      if (result is Failure<void>) return result;
      // 纯拒绝同样参与自动回滚监控（新版本后连续被拒绝是召回信号）。
      checkAutoRollback();
      return const Success(null);
    }
    final candidate = parseCorrection(detail);
    final target = candidate == null
        ? '$targetPrefix:$id'
        : '$feedbackTargetPolicy:${candidate.$1}';
    final result = _collector.record(
      FeedbackVerdict.corrected,
      target: target,
      detail: detail,
    );
    if (result is Failure<void>) return result;
    if (candidate != null) {
      proposeFromCorrection(detail);
    } else {
      // 规则未命中 → LLM 二级解析（含次数门槛，异步不阻塞）。
      unawaited(_maybeParseWithLlm(detail));
    }
    checkAutoRollback();
    return const Success(null);
  }

  String _proposalField(String id) {
    for (final proposal in _policy.proposals) {
      if (proposal.id == id) return proposal.field;
    }
    return 'unknown';
  }

  String _entryId() => '${_clock().microsecondsSinceEpoch}-${_sequence++}';

  static bool _containsAny(String text, List<String> needles) =>
      needles.any(text.contains);
}
