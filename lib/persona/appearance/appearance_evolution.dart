/// 形象演化推演：纯函数，由情绪三维 + 人格 + 近期反馈决定「是否变、往哪变」。
///
/// 防跑偏的四道闸：
/// 1. 冻结优先——frozen 时一律不动；
/// 2. 冷却——两次演化至少间隔 [evolutionCooldown]；
/// 3. 单步——一次最多改一个维度、枚举只移动一格、体型缩放只移动一格；
/// 4. 阈值——信号强度不够时宁可不改（理由会写明「信号不足」）。
/// 形态是最显眼的变化，不自动应用：条件满足时只产出 [AppearanceProposal]，
/// 等用户在设置页接受后才落盘，拒绝即丢弃。
/// 输出永远带一条可读理由，设置页直接展示「为什么变了」。
library;

import 'appearance_proposal.dart';
import 'appearance_state.dart';

/// 两次自动演化的最小间隔。
const Duration evolutionCooldown = Duration(hours: 12);

/// 单次体型缩放的步进。
const double appearanceScaleStep = 0.02;

/// 参与推演的信号快照（由内核从情绪/人格/学习层汇总）。
class AppearanceSignals {
  const AppearanceSignals({
    required this.valence,
    required this.arousal,
    required this.intimacy,
    required this.proactiveness,
    required this.acceptedCount,
    required this.rejectedCount,
    required this.correctedCount,
    required this.now,
  });

  /// 情绪效价 [-1, 1]。
  final double valence;

  /// 唤醒度 [0, 1]。
  final double arousal;

  /// 亲密度 [0, 1]。
  final double intimacy;

  /// 人格 DNA 的主动性 [0, 1]。
  final double proactiveness;

  /// 近期（24h）反馈计数。
  final int acceptedCount;
  final int rejectedCount;
  final int correctedCount;

  final DateTime now;

  int get negativeCount => rejectedCount + correctedCount;
  int get positiveCount => acceptedCount;

  /// 净反馈强度：正负样本差，范围 [-1, 1]。
  double get feedbackBalance {
    final total = positiveCount + negativeCount;
    if (total == 0) return 0;
    return (positiveCount - negativeCount) / total;
  }
}

class EvolutionOutcome {
  const EvolutionOutcome({
    required this.state,
    required this.changed,
    required this.reason,
    this.proposal,
  });

  final AppearanceState state;
  final bool changed;

  /// 形态建议（需用户接受才生效）；其余维度为自动应用。
  final AppearanceProposal? proposal;

  /// 可解释理由：变了什么、为什么；没变也会说明原因。
  final String reason;
}

class AppearanceEvolution {
  const AppearanceEvolution({
    this.cooldown = evolutionCooldown,
    this.minSignal = 0.25,
  });

  final Duration cooldown;

  /// 低于该净反馈强度就不动，避免一两次零星反馈就改形象。
  final double minSignal;

  EvolutionOutcome evolve(AppearanceState current, AppearanceSignals signals) {
    if (current.frozen) {
      return EvolutionOutcome(
        state: current,
        changed: false,
        reason: '形象已冻结，自动演化暂停',
      );
    }
    final elapsed = signals.now.difference(current.updatedAt);
    if (current.revision > 0 && elapsed < cooldown) {
      final hours = cooldown.inHours - elapsed.inHours;
      return EvolutionOutcome(
        state: current,
        changed: false,
        reason: '距离上次变化不足 ${cooldown.inHours} 小时，还需约 $hours 小时',
      );
    }

    final balance = signals.feedbackBalance;
    if (balance.abs() < minSignal) {
      return EvolutionOutcome(
        state: current,
        changed: false,
        reason: '近期反馈信号不足（净强度 ${balance.toStringAsFixed(2)}），保持现状',
      );
    }

    final next = _applyOneStep(current, signals, balance);
    if (next.signature != current.signature) {
      return EvolutionOutcome(
        state: next.copyWith(
          revision: current.revision + 1,
          updatedAtMs: signals.now.millisecondsSinceEpoch,
        ),
        changed: true,
        reason: _explain(current, next, signals, balance),
      );
    }

    // 其它维度都动不了时才考虑形态：只提案，不动状态。
    final proposal = _formProposal(current, signals, balance);
    if (proposal != null) {
      return EvolutionOutcome(
        state: current,
        changed: false,
        reason: proposal.reason,
        proposal: proposal,
      );
    }
    return EvolutionOutcome(
      state: current,
      changed: false,
      reason: '已到该方向的可调整边界，保持现状',
    );
  }

  /// 只改一个维度；按优先级依次尝试，第一个能移动的项目胜出。
  AppearanceState _applyOneStep(
    AppearanceState current,
    AppearanceSignals signals,
    double balance,
  ) {
    final positive = balance > 0;

    // 1) 负反馈足够强时先收动作组（最直观地"安静下来"）。
    if (!positive && signals.negativeCount >= 2) {
      final next = _stepEnum(
        AppearanceMotionSet.values,
        current.motionSet,
        1,
      );
      if (next != null) return current.copyWith(motionSet: next);
    }

    // 2) 动作组：唤醒度高低决定活泼/困倦。
    final motionTarget = signals.arousal >= 0.6
        ? AppearanceMotionSet.lively
        : (signals.arousal <= 0.15
              ? AppearanceMotionSet.sleepy
              : AppearanceMotionSet.calm);
    final motionNext = _stepEnum(
      AppearanceMotionSet.values,
      current.motionSet,
      _direction(current.motionSet.index, motionTarget.index),
    );
    if (motionNext != null && motionNext != current.motionSet) {
      return current.copyWith(motionSet: motionNext);
    }

    // 3) 表情集：效价正/负决定明亮或柔和；高唤醒叠加活泼倾向。
    final expressionTarget = signals.valence >= 0.2
        ? AppearanceExpressionSet.bright
        : (signals.valence <= -0.2
              ? AppearanceExpressionSet.soft
              : AppearanceExpressionSet.cool);
    final expressionNext = _stepEnum(
      AppearanceExpressionSet.values,
      current.expressionSet,
      _direction(current.expressionSet.index, expressionTarget.index),
    );
    if (expressionNext != null && expressionNext != current.expressionSet) {
      return current.copyWith(expressionSet: expressionNext);
    }

    // 4) 配饰：亲密度足够高才递进，低亲密度不倒退（已获得的配饰保留）。
    if (signals.intimacy >= 0.6) {
      final next = _stepEnum(
        AppearanceAccessory.values,
        current.accessory,
        1,
      );
      if (next != null) return current.copyWith(accessory: next);
    }

    // 5) 体型：主动性高则略微放大，低则略微收小；每步只走一格。
    final scaleTarget = signals.proactiveness >= 0.6
        ? appearanceScaleStep
        : (signals.proactiveness <= 0.3 ? -appearanceScaleStep : 0.0);
    if (scaleTarget != 0) {
      final next = AppearanceState.clampBodyScale(
        current.bodyScale + scaleTarget,
      );
      if ((next - current.bodyScale).abs() > 1e-6) {
        return current.copyWith(bodyScale: next);
      }
    }

    return current;
  }

  /// 形态提案：只在长期正向且高唤醒时递进一格；负向不动（不会越变越怪）。
  AppearanceProposal? _formProposal(
    AppearanceState current,
    AppearanceSignals signals,
    double balance,
  ) {
    if (balance < 0.6 || signals.arousal < 0.7) return null;
    final next = _stepEnum(AppearanceForm.values, current.form, 1);
    if (next == null) return null;
    return AppearanceProposal(
      id:
          'form-${current.form.name}-${next.name}-'
          '${signals.now.microsecondsSinceEpoch}',
      targetForm: next,
      reason:
          '形态建议：${current.form.name} → ${next.name}'
          '（依据：长期正反馈、唤醒度较高；确认后才生效）',
      createdAtMs: signals.now.millisecondsSinceEpoch,
    );
  }

  /// 枚举相邻移动：越界返回 null；目标与当前相同时返回 null（无需变）。
  static T? _stepEnum<T extends Enum>(List<T> values, T current, int direction) {
    if (direction == 0) return null;
    final index = current.index + (direction > 0 ? 1 : -1);
    if (index < 0 || index >= values.length) return null;
    return values[index];
  }

  static int _direction(int from, int to) {
    if (to > from) return 1;
    if (to < from) return -1;
    return 0;
  }

  /// 生成一句人能读懂的变更说明（设置页原样展示）。
  String _explain(
    AppearanceState before,
    AppearanceState after,
    AppearanceSignals signals,
    double balance,
  ) {
    final parts = <String>[];
    if (before.motionSet != after.motionSet) {
      parts.add('动作组 ${before.motionSet.name} → ${after.motionSet.name}');
    }
    if (before.expressionSet != after.expressionSet) {
      parts.add(
        '表情集 ${before.expressionSet.name} → ${after.expressionSet.name}',
      );
    }
    if (before.accessory != after.accessory) {
      parts.add('配饰 ${before.accessory.name} → ${after.accessory.name}');
    }
    if ((before.bodyScale - after.bodyScale).abs() > 1e-6) {
      parts.add(
        '体型缩放 ${before.bodyScale.toStringAsFixed(2)}'
        ' → ${after.bodyScale.toStringAsFixed(2)}',
      );
    }
    if (before.form != after.form) {
      parts.add('形态 ${before.form.name} → ${after.form.name}');
    }
    final trend = balance > 0 ? '正反馈偏多' : '负反馈偏多';
    return '${parts.isEmpty ? '无变化' : parts.join('；')}'
        '（依据：$trend，净强度 ${balance.toStringAsFixed(2)}；'
        '情绪 v=${signals.valence.toStringAsFixed(2)} '
        'a=${signals.arousal.toStringAsFixed(2)} '
        'i=${signals.intimacy.toStringAsFixed(2)}）';
  }
}
