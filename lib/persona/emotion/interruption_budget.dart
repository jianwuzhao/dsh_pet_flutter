/// 主动打扰预算：所有“主动开口”必过的闸门（计划 4.3）。
///
/// 纯计算器：只读档案做判定，消耗后返回新档案，持久化由调用方负责。
/// 时钟可注入，安静时段/日限翻转都能离线测试。
library;

import '../profile_store.dart';
import 'emotion_machine.dart';

class InterruptionBudget {
  InterruptionBudget({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// 安静时段判定：HH:mm 支持跨零点（22:00–08:00）；起止相同视为没有安静时段。
  bool inQuietHours(EmotionProfile profile, {DateTime? at}) {
    final now = at ?? _clock();
    final start = _minutesOfDay(profile.quietStart);
    final end = _minutesOfDay(profile.quietEnd);
    if (start == null || end == null || start == end) return false;
    final minute = now.hour * 60 + now.minute;
    if (start < end) return minute >= start && minute < end;
    return minute >= start || minute < end;
  }

  /// 五道闸门全过才允许主动表达：
  /// 一键关 / 人格主动度为 0 / 专注模式 / 安静时段 / 日限+同状态 1h 限流。
  /// 情绪态的被动表达（动画切换）不走这里，只有“主动开口”才消耗预算。
  bool allow(
    EmotionProfile profile, {
    required EmotionPhase phase,
    double proactiveness = 1,
  }) {
    if (!profile.careEnabled) return false;
    if (proactiveness <= 0) return false;
    if (profile.focusMode) return false;
    if (inQuietHours(profile)) return false;
    final now = _clock();
    if (_isSameDay(profile.careDate, now) &&
        profile.careCount >= profile.dailyCareLimit) {
      return false;
    }
    final sameStateRecently =
        profile.lastCareState == phase.name &&
        now.millisecondsSinceEpoch - profile.lastCareAtMs <
            const Duration(hours: 1).inMilliseconds;
    return !sameStateRecently;
  }

  /// 消耗一次额度：日期翻转清零、计数 +1、记录状态与时间。
  /// 返回新档案，写盘由调用方决定（表达失败时不该扣额度）。
  EmotionProfile consume(
    EmotionProfile profile, {
    required EmotionPhase phase,
  }) {
    final now = _clock();
    final today = _dayKey(now);
    final count = _isSameDay(profile.careDate, now) ? profile.careCount + 1 : 1;
    return profile.copyWith(
      careDate: today,
      careCount: count,
      lastCareAtMs: now.millisecondsSinceEpoch,
      lastCareState: phase.name,
    );
  }

  static String _dayKey(DateTime now) =>
      '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';

  static bool _isSameDay(String careDate, DateTime now) =>
      careDate.isNotEmpty && careDate == _dayKey(now);

  static int? _minutesOfDay(String raw) {
    final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(raw.trim());
    if (match == null) return null;
    final hour = int.parse(match.group(1)!);
    final minute = int.parse(match.group(2)!);
    if (hour > 23 || minute > 59) return null;
    return hour * 60 + minute;
  }
}
