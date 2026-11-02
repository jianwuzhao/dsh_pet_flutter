/// 情绪状态机：连续三维 → 离散五态映射 + 转换节流。
///
/// 判定顺序（计划 4.2，先后不可换）：
/// sleepy(a<0.15) → excited(v>0.2 && a>0.6) → happy(v>0.2)
/// → worried(v<-0.2 && a>0.4) → calm。
/// 常规 90s 内不换态；|Δv|+|Δa| > 0.4 的强信号立即换。
library;

import 'emotion_state.dart';

enum EmotionPhase { sleepy, excited, happy, worried, calm }

class EmotionMachine {
  EmotionMachine({DateTime? now})
    : _lastSwitchAt = now ?? DateTime.now();

  EmotionPhase _phase = EmotionPhase.calm;
  DateTime _lastSwitchAt;
  DateTime? _worriedSince;

  EmotionPhase get phase => _phase;

  /// worried 已持续多久；不在 worried 态返回 Duration.zero。
  /// 内核用“持续>3min”触发主动关心（还要再过打扰预算）。
  Duration worriedFor({DateTime? now}) {
    final since = _worriedSince;
    if (since == null) return Duration.zero;
    return (now ?? DateTime.now()).difference(since);
  }

  /// 纯映射：不节流、不改状态，测试与外部预览用。
  static EmotionPhase map(EmotionState state) {
    if (state.arousal < 0.15) return EmotionPhase.sleepy;
    if (state.valence > 0.2 && state.arousal > 0.6) {
      return EmotionPhase.excited;
    }
    if (state.valence > 0.2) return EmotionPhase.happy;
    if (state.valence < -0.2 && state.arousal > 0.4) {
      return EmotionPhase.worried;
    }
    return EmotionPhase.calm;
  }

  /// 带节流的更新：常规 90s 内不换态，强信号（impulse>0.4）立即换。
  /// 返回更新后的当前态（可能与映射目标不同）。
  EmotionPhase update(EmotionState state, {double impulse = 0, DateTime? now}) {
    final at = now ?? DateTime.now();
    final target = map(state);
    if (target == _phase) return _phase;
    final strong = impulse > 0.4;
    final sinceSwitch = at.difference(_lastSwitchAt);
    if (!strong && sinceSwitch < const Duration(seconds: 90)) {
      return _phase;
    }
    final previous = _phase;
    _phase = target;
    _lastSwitchAt = at;
    // worried 计时只在“真正进入”时开始；被节流拦下的换态不刷新它。
    if (target == EmotionPhase.worried && previous != EmotionPhase.worried) {
      _worriedSince = at;
    } else if (target != EmotionPhase.worried) {
      _worriedSince = null;
    }
    return _phase;
  }

  /// 外部强制换态（如情绪引擎被关闭时复位到 calm）。
  void reset({DateTime? now}) {
    _phase = EmotionPhase.calm;
    _lastSwitchAt = now ?? DateTime.now();
    _worriedSince = null;
  }
}
