/// 情绪三维状态：效价/唤醒/亲密度 + 衰减 + 钳制。
///
/// 数值口径见计划 4.2：基线 v=0/a=0.3、亲密度基线从档案读；
/// 60s 一拍向基线回归；每分钟累计 |Δv| ≤ 0.3 防刷屏；空闲压唤醒。
library;

import 'dart:math' as math;

import 'emotion_signal.dart';

/// 供 UI 与状态机读取的不可变快照。
class EmotionView {
  const EmotionView({
    required this.valence,
    required this.arousal,
    required this.intimacy,
  });

  final double valence;
  final double arousal;
  final double intimacy;
}

class EmotionState {
  EmotionState({this.intimacyBaseline = 0.3}) : intimacy = intimacyBaseline;

  /// 效价 ∈ [-1,1]：负=消极，正=积极。
  double valence = 0;

  /// 唤醒 ∈ [0,1]：低=困倦，高=激动。
  double arousal = 0.3;

  /// 亲密度 ∈ [0,1]：慢变量，长期互动才会移动，基线从情绪档案读。
  double intimacy;

  final double intimacyBaseline;

  /// 60s 滚动窗口的 |Δv| 记录（时间 → 增量绝对值）。
  final List<MapEntry<DateTime, double>> _vJitter = [];

  static const Duration _jitterWindow = Duration(seconds: 60);

  /// 每分钟累计 |Δv| 上限：情绪不能被连发消息刷上天。
  static const double _jitterCap = 0.3;

  EmotionView get view =>
      EmotionView(valence: valence, arousal: arousal, intimacy: intimacy);

  /// 应用一个信号，返回 impulse = |Δv| + |Δa|（钳制前的原始强度，
  /// 状态机用它识别“强信号立即换态”）。
  double apply(EmotionSignal signal, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final delta = signalDeltas[signal]!;
    final dv = _spendValenceBudget(delta.valence, at);
    valence = (valence + dv).clamp(-1.0, 1.0);
    arousal = (arousal + delta.arousal).clamp(0.0, 1.0);
    intimacy = (intimacy + delta.intimacy).clamp(0.0, 1.0);
    return dv.abs() + delta.arousal.abs();
  }

  /// 60s 一拍向基线回归（回归不算信号，不记抖动窗口）。
  void decayTick() {
    valence += (0 - valence) * 0.1;
    arousal += (0.3 - arousal) * 0.15;
    intimacy += (intimacyBaseline - intimacy) * 0.02;
  }

  /// 空闲 >30min：直接压到困倦唤醒水平（计划 4.2）。
  void applyIdleFatigue() {
    if (arousal >= 0.15) arousal = 0.12;
  }

  /// 在抖动预算内截断 Δv：窗口内累计已达上限时 v 分量归零。
  double _spendValenceBudget(double dv, DateTime at) {
    _vJitter.removeWhere(
      (entry) => at.difference(entry.key) > _jitterWindow,
    );
    if (dv == 0) return 0;
    var spent = 0.0;
    for (final entry in _vJitter) {
      spent += entry.value;
    }
    final remaining = math.max(0.0, _jitterCap - spent);
    final allowed = _clampAbs(dv, remaining);
    if (allowed != 0) _vJitter.add(MapEntry(at, allowed.abs()));
    return allowed;
  }

  static double _clampAbs(double value, double limit) {
    if (limit <= 0) return 0;
    return value > 0
        ? math.min(value, limit)
        : math.max(value, -limit);
  }
}
