import 'package:dsh_pet_flutter/persona/emotion/emotion_signal.dart';
import 'package:dsh_pet_flutter/persona/emotion/emotion_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final base = DateTime(2026, 11, 2, 12, 0);

  group('信号映射', () {
    test('sentiment 标签映射四类，neutral/未知为 null', () {
      expect(signalFromSentiment('positive'), EmotionSignal.positiveFeedback);
      expect(signalFromSentiment('negative'), EmotionSignal.negativeFeedback);
      expect(signalFromSentiment('tired'), EmotionSignal.tired);
      expect(signalFromSentiment('excited'), EmotionSignal.excited);
      expect(signalFromSentiment('neutral'), isNull);
      expect(signalFromSentiment(null), isNull);
      expect(signalFromSentiment('weird'), isNull);
    });

    test('关键词启发式：疲惫优先于兴奋与正负', () {
      expect(guessSignalFromText('今天好累'), EmotionSignal.tired);
      expect(guessSignalFromText('太好了，成功了！'), EmotionSignal.excited);
      expect(guessSignalFromText('谢谢，很好用'), EmotionSignal.positiveFeedback);
      expect(guessSignalFromText('不对，这个错了'), EmotionSignal.negativeFeedback);
      expect(guessSignalFromText('今天天气不错'), isNull);
    });
  });

  group('EmotionState 应用信号', () {
    test('正反馈按常量表移动三维', () {
      final state = EmotionState(intimacyBaseline: 0.3);
      final impulse = state.apply(
        EmotionSignal.positiveFeedback,
        now: base,
      );
      expect(state.valence, closeTo(0.2, 1e-9));
      expect(state.arousal, closeTo(0.4, 1e-9));
      expect(state.intimacy, closeTo(0.32, 1e-9));
      // impulse = |Δv| + |Δa| = 0.2 + 0.1
      expect(impulse, closeTo(0.3, 1e-9));
    });

    test('唤醒与亲密度钳制在 [0,1]，效价在 [-1,1]', () {
      final state = EmotionState(intimacyBaseline: 0.3);
      for (var i = 0; i < 20; i++) {
        state.apply(
          EmotionSignal.negativeFeedback,
          now: base.add(Duration(minutes: 2 * i)),
        );
      }
      expect(state.valence, greaterThanOrEqualTo(-1));
      expect(state.arousal, lessThanOrEqualTo(1));
      expect(state.intimacy, greaterThanOrEqualTo(0));
    });

    test('每分钟累计 |Δv| ≤ 0.3：窗口内连发正反馈被截断', () {
      final state = EmotionState();
      // 两次正反馈共 Δv=0.4，第二次只能再花 0.1。
      state.apply(EmotionSignal.positiveFeedback, now: base);
      state.apply(EmotionSignal.positiveFeedback, now: base);
      expect(state.valence, closeTo(0.3, 1e-9));
      // 窗口滑出后预算恢复。
      state.apply(
        EmotionSignal.positiveFeedback,
        now: base.add(const Duration(seconds: 61)),
      );
      expect(state.valence, closeTo(0.5, 1e-9));
    });
  });

  group('EmotionState 衰减', () {
    test('60s 一拍向基线回归', () {
      final state = EmotionState(intimacyBaseline: 0.5);
      state.apply(EmotionSignal.excited, now: base);
      final beforeV = state.valence;
      final beforeI = state.intimacy;
      state.decayTick();
      // v: 0.3 → 0.3 - 0.3*0.1 = 0.27
      expect(state.valence, closeTo(beforeV * 0.9, 1e-9));
      expect(beforeV, closeTo(0.3, 1e-9));
      // i: 0.5+0=0.5 → 0.5 + (0.5-0.5)*0.02 = 0.5（excited 不动亲密度）
      expect(state.intimacy, closeTo(beforeI, 1e-9));
      state.decayTick();
      state.decayTick();
      // 多拍单调靠近基线。
      expect(state.valence, lessThan(beforeV * 0.9));
    });

    test('亲密度向档案基线慢回归', () {
      final state = EmotionState(intimacyBaseline: 0.3);
      // 互动把亲密度抬到 0.5（模拟多次互动累计）。
      for (var i = 0; i < 40; i++) {
        state.apply(
          EmotionSignal.interaction,
          now: base.add(Duration(seconds: 90 * i)),
        );
      }
      final raised = state.intimacy;
      expect(raised, greaterThan(0.3));
      state.decayTick();
      // i += (0.3 - i) * 0.02：向下靠近 0.3。
      expect(state.intimacy, lessThan(raised));
      expect(state.intimacy, greaterThan(0.3));
    });

    test('空闲疲劳把唤醒压到困倦水平', () {
      final state = EmotionState();
      state.apply(EmotionSignal.excited, now: base);
      expect(state.arousal, greaterThan(0.15));
      state.applyIdleFatigue();
      expect(state.arousal, lessThan(0.15));
      // 已经低于阈值则不动。
      final low = state.arousal;
      state.applyIdleFatigue();
      expect(state.arousal, low);
    });
  });
}
