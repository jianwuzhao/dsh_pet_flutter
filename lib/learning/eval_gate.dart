/// 评估门禁：候选策略变更能不能进入应用的唯一裁判（计划 4.5）。
///
/// 三道关：
/// 1. 安全边界硬拒绝——身份/价值观/隐私/打扰上限/人格底线永远不放行；
/// 2. 样本量——同向样本 ≥3 才允许提案；反向样本更多则拒绝；
/// 3. 三级（知识/检索）与四级（参数微调）本轮未开放，直接拒绝并注明。
/// 门禁只管“能不能提案”，真正的生效仍要用户在接受提案时点头。
library;

import 'policy_store.dart';

enum GateVerdict { approve, reject }

class GateResult {
  const GateResult({
    required this.verdict,
    required this.reason,
    this.field = '',
    this.value = '',
  });

  final GateVerdict verdict;
  final String reason;

  /// 通过时带回被批准的字段与目标值。
  final String field;
  final String value;

  bool get approved => verdict == GateVerdict.approve;
}

class EvalGate {
  const EvalGate({this.minSamples = 3});

  /// 同向样本下限（计划 4.5：≥3 条同向样本）。
  final int minSamples;

  /// 策略字段变更的门禁。
  GateResult reviewPolicyChange({
    required String field,
    required String value,
    required int supporting,
    int opposing = 0,
  }) {
    if (protectedFields.contains(field)) {
      return GateResult(
        verdict: GateVerdict.reject,
        reason: '「$field」属于安全边界，不允许通过学习改变',
        field: field,
        value: value,
      );
    }
    if (!learnableFields.contains(field)) {
      return GateResult(
        verdict: GateVerdict.reject,
        reason: '「$field」不是可学习的表达偏好字段',
        field: field,
        value: value,
      );
    }
    if (!(PolicyParams.allowedValues[field]?.contains(value) ?? false)) {
      return GateResult(
        verdict: GateVerdict.reject,
        reason: '策略值「$value」不在允许范围内',
        field: field,
        value: value,
      );
    }
    if (supporting < minSamples) {
      return GateResult(
        verdict: GateVerdict.reject,
        reason: '同向样本不足（$supporting/$minSamples），继续观察',
        field: field,
        value: value,
      );
    }
    if (opposing >= supporting) {
      return GateResult(
        verdict: GateVerdict.reject,
        reason: '反向样本不低于同向样本（$opposing/$supporting），不做变更',
        field: field,
        value: value,
      );
    }
    return GateResult(
      verdict: GateVerdict.approve,
      reason: '样本充足（$supporting 条同向），可以提案',
      field: field,
      value: value,
    );
  }

  /// 学习层级门禁：首期只开放一、二级（记忆/策略）。
  GateResult reviewLearningLevel(int level) {
    if (level <= 2) {
      return GateResult(verdict: GateVerdict.approve, reason: '首期开放的学习层级');
    }
    return GateResult(
      verdict: GateVerdict.reject,
      reason: '第 $level 级学习（知识检索/参数微调）尚未开放',
    );
  }
}
