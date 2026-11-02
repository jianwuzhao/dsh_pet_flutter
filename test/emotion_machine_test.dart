import 'package:dsh_pet_flutter/persona/emotion/emotion_machine.dart';
import 'package:dsh_pet_flutter/persona/emotion/emotion_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final base = DateTime(2026, 11, 2, 12, 0);

  EmotionState stateAt({double v = 0, double a = 0.3}) {
    final state = EmotionState();
    state.valence = v;
    state.arousal = a;
    return state;
  }

  group('五态映射（判定顺序不可换）', () {
    test('sleepy: a<0.15', () {
      expect(EmotionMachine.map(stateAt(v: 0.5, a: 0.1)), EmotionPhase.sleepy);
    });

    test('excited: v>0.2 && a>0.6', () {
      expect(
        EmotionMachine.map(stateAt(v: 0.3, a: 0.7)),
        EmotionPhase.excited,
      );
      // 唤醒不够退到 happy。
      expect(EmotionMachine.map(stateAt(v: 0.3, a: 0.5)), EmotionPhase.happy);
    });

    test('happy: v>0.2 且唤醒不高', () {
      expect(EmotionMachine.map(stateAt(v: 0.25, a: 0.3)), EmotionPhase.happy);
    });

    test('worried: v<-0.2 && a>0.4', () {
      expect(
        EmotionMachine.map(stateAt(v: -0.3, a: 0.5)),
        EmotionPhase.worried,
      );
      // 唤醒不够则 calm（低落由语气变体处理，不加态）。
      expect(EmotionMachine.map(stateAt(v: -0.3, a: 0.3)), EmotionPhase.calm);
    });

    test('calm: 其余', () {
      expect(EmotionMachine.map(stateAt(v: 0, a: 0.3)), EmotionPhase.calm);
      expect(EmotionMachine.map(stateAt(v: 0.1, a: 0.9)), EmotionPhase.calm);
    });
  });

  group('转换节流', () {
    test('常规 90s 内不换态', () {
      final machine = EmotionMachine(now: base);
      expect(machine.phase, EmotionPhase.calm);
      // 强信号立即切到 excited。
      final state = stateAt(v: 0.3, a: 0.7);
      expect(
        machine.update(state, impulse: 0.55, now: base),
        EmotionPhase.excited,
      );
      // 90s 内普通信号不换回 calm。
      final calmState = stateAt(v: 0, a: 0.3);
      expect(
        machine.update(calmState, now: base.add(const Duration(seconds: 30))),
        EmotionPhase.excited,
      );
      // 90s 过后可以换。
      expect(
        machine.update(
          calmState,
          now: base.add(const Duration(seconds: 91)),
        ),
        EmotionPhase.calm,
      );
    });

    test('弱信号在节流窗口内被拦下', () {
      final machine = EmotionMachine(now: base);
      final state = stateAt(v: 0.3, a: 0.7);
      // impulse 0.3 < 0.4：不触发立即换。
      expect(
        machine.update(state, impulse: 0.3, now: base),
        EmotionPhase.calm,
      );
      // 窗口过后同一目标可以换。
      expect(
        machine.update(
          state,
          now: base.add(const Duration(seconds: 91)),
        ),
        EmotionPhase.excited,
      );
    });

    test('同态重复 update 不换', () {
      final machine = EmotionMachine(now: base);
      final state = stateAt(v: 0, a: 0.3);
      expect(machine.update(state, now: base), EmotionPhase.calm);
      expect(machine.update(state, now: base), EmotionPhase.calm);
    });
  });

  group('worried 持续计时', () {
    test('进入 worried 开始计时，离开清零', () {
      final machine = EmotionMachine(now: base);
      final worried = stateAt(v: -0.3, a: 0.5);
      expect(machine.update(worried, impulse: 0.5, now: base),
          EmotionPhase.worried);
      expect(
        machine.worriedFor(now: base.add(const Duration(minutes: 4))),
        const Duration(minutes: 4),
      );
      machine.update(
        stateAt(v: 0, a: 0.3),
        now: base.add(const Duration(minutes: 5)),
      );
      expect(
        machine.worriedFor(now: base.add(const Duration(minutes: 6))),
        Duration.zero,
      );
    });

    test('reset 回到 calm', () {
      final machine = EmotionMachine(now: base);
      machine.update(stateAt(v: -0.3, a: 0.5), impulse: 0.5, now: base);
      machine.reset();
      expect(machine.phase, EmotionPhase.calm);
      expect(machine.worriedFor(now: base), Duration.zero);
    });
  });
}
