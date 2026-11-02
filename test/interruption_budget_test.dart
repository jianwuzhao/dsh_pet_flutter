import 'package:dsh_pet_flutter/persona/emotion/emotion_machine.dart';
import 'package:dsh_pet_flutter/persona/emotion/interruption_budget.dart';
import 'package:dsh_pet_flutter/persona/profile_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 固定时钟：周一 2026-11-02 12:00（安静时段 22:00–08:00 之外）。
  var now = DateTime(2026, 11, 2, 12, 0);
  late InterruptionBudget budget;

  setUp(() {
    budget = InterruptionBudget(clock: () => now);
  });

  EmotionProfile profile([
    EmotionProfile Function(EmotionProfile)? tweak,
  ]) => tweak == null ? const EmotionProfile() : tweak(const EmotionProfile());

  group('一键关与人格约束', () {
    test('careEnabled=false 一票否决', () {
      final p = profile((e) => e.copyWith(careEnabled: false));
      expect(budget.allow(p, phase: EmotionPhase.worried), isFalse);
    });

    test('人格主动度为 0 完全被动', () {
      expect(
        budget.allow(
          profile((e) => e),
          phase: EmotionPhase.worried,
          proactiveness: 0,
        ),
        isFalse,
      );
    });

    test('专注模式静默', () {
      final p = profile((e) => e.copyWith(focusMode: true));
      expect(budget.allow(p, phase: EmotionPhase.worried), isFalse);
    });
  });

  group('安静时段', () {
    test('默认 22:00–08:00：深夜拒绝、白天放行、跨零点正确', () {
      now = DateTime(2026, 11, 2, 23, 30);
      expect(budget.inQuietHours(profile((e) => e)), isTrue);
      now = DateTime(2026, 11, 3, 2, 0);
      expect(budget.inQuietHours(profile((e) => e)), isTrue);
      now = DateTime(2026, 11, 2, 7, 59);
      expect(budget.inQuietHours(profile((e) => e)), isTrue);
      now = DateTime(2026, 11, 2, 8, 0);
      expect(budget.inQuietHours(profile((e) => e)), isFalse);
      now = DateTime(2026, 11, 2, 12, 0);
      expect(budget.inQuietHours(profile((e) => e)), isFalse);
      // 安静时段内 allow 一律拒绝。
      now = DateTime(2026, 11, 2, 23, 30);
      expect(budget.allow(profile((e) => e), phase: EmotionPhase.worried), isFalse);
    });

    test('非跨零点时段（如 12:00–13:30）', () {
      final p = profile(
        (e) => e.copyWith(quietStart: '12:00', quietEnd: '13:30'),
      );
      now = DateTime(2026, 11, 2, 12, 30);
      expect(budget.inQuietHours(p), isTrue);
      now = DateTime(2026, 11, 2, 13, 30);
      expect(budget.inQuietHours(p), isFalse);
    });

    test('起止相同视为无安静时段；非法时间不生效', () {
      final same = profile(
        (e) => e.copyWith(quietStart: '09:00', quietEnd: '09:00'),
      );
      now = DateTime(2026, 11, 2, 9, 0);
      expect(budget.inQuietHours(same), isFalse);
      final broken = profile(
        (e) => e.copyWith(quietStart: '9点', quietEnd: 'bad'),
      );
      expect(budget.inQuietHours(broken), isFalse);
    });
  });

  group('日限与同状态限流', () {
    test('当日计数达到 dailyCareLimit 后拒绝', () {
      final day = '2026-11-02';
      final p = profile(
        (e) => e.copyWith(
          careDate: day,
          careCount: 3,
          lastCareAtMs: 0,
          lastCareState: '',
        ),
      );
      expect(budget.allow(p, phase: EmotionPhase.worried), isFalse);
      // 未达限则放行。
      final under = profile(
        (e) => e.copyWith(careDate: day, careCount: 2, lastCareState: ''),
      );
      expect(budget.allow(under, phase: EmotionPhase.worried), isTrue);
    });

    test('同状态 1 小时内最多一次', () {
      final ms = DateTime(2026, 11, 2, 11, 30).millisecondsSinceEpoch;
      final p = profile(
        (e) => e.copyWith(
          lastCareAtMs: ms,
          lastCareState: 'worried',
          careDate: '2026-11-02',
          careCount: 1,
        ),
      );
      // 11:30 关心过，12:00 同状态拒绝。
      expect(budget.allow(p, phase: EmotionPhase.worried), isFalse);
      // 换个状态可以（预算内）。
      expect(budget.allow(p, phase: EmotionPhase.sleepy), isTrue);
      // 12:31 之后同状态恢复。
      now = DateTime(2026, 11, 2, 12, 31);
      expect(budget.allow(p, phase: EmotionPhase.worried), isTrue);
    });

    test('日期翻转后计数清零', () {
      final p = profile(
        (e) => e.copyWith(careDate: '2026-11-01', careCount: 3),
      );
      expect(budget.allow(p, phase: EmotionPhase.worried), isTrue);
    });
  });

  group('consume', () {
    test('计数 +1 并记录状态与时间', () {
      final consumed = budget.consume(
        profile((e) => e),
        phase: EmotionPhase.worried,
      );
      expect(consumed.careDate, '2026-11-02');
      expect(consumed.careCount, 1);
      expect(consumed.lastCareState, 'worried');
      expect(
        consumed.lastCareAtMs,
        now.millisecondsSinceEpoch,
      );
    });

    test('旧日期计数翻转归 1', () {
      final consumed = budget.consume(
        profile((e) => e.copyWith(careDate: '2026-11-01', careCount: 3)),
        phase: EmotionPhase.sleepy,
      );
      expect(consumed.careCount, 1);
    });
  });
}
