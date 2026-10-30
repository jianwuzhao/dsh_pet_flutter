/// 漫游：一次移动动画里水平位移多少、首尾各停多久。
///
/// 上游用「基准宠物宽 462px」定义 minDist/maxDist，运行时按 实际size/462 等比缩放；
/// 这里保留同一口径，保证不同大小的宠物步幅观感一致。
library;

import 'dart:math' as math;

import '../../../core/config/animation_manifest.dart';

const double upstreamBaseWidth = 462;

class MovePlan {
  const MovePlan({
    required this.distance,
    required this.lead,
    required this.tail,
    required this.direction,
  });

  /// 本次行进距离（逻辑像素，已按宠物大小缩放）。
  final double distance;
  final Duration lead;
  final Duration tail;
  final int direction;

  /// 在动画总时长内，按 lead/tail 留白后的时间比例算出当前水平偏移。
  double offsetAt(Duration elapsed, Duration total) {
    final start = lead.inMicroseconds.toDouble();
    final end = math.max(
      start + 1,
      total.inMicroseconds.toDouble() - tail.inMicroseconds,
    );
    final now = elapsed.inMicroseconds.toDouble();
    if (now <= start) return 0;
    final progress = now >= end ? 1.0 : (now - start) / (end - start);
    return distance * progress * direction;
  }
}

MovePlan planMove(
  MoveParams params, {
  required double petSize,
  required int facing,
}) {
  final scale = petSize / upstreamBaseWidth;
  final minDist = params.minDist * scale;
  final maxDist = math.max(minDist, params.maxDist * scale);
  final distance = minDist + (maxDist - minDist) * math.Random().nextDouble();
  return MovePlan(
    distance: distance,
    lead: Duration(milliseconds: (params.leadSec * 1000).round()),
    tail: Duration(milliseconds: (params.tailSec * 1000).round()),
    direction: facing,
  );
}
