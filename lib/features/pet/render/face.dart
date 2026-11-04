/// 表情参数化（P2-4）：四态表情集 → 参数 → 程序化绘制。
///
/// 计划原案是 FluentEmoji SVG + flutter_svg；实际无素材、无依赖，
/// 与装扮层（wardrobe）同理裁剪为纯参数化绘制——参数模型保持
/// 「眼睛开合/眉毛角度/嘴形弧度」三维 + 腮红，未来接 SVG 素材时
/// 参数直接喂给 SVG 变形，调用方接口不变。
library;

import 'dart:math' as math;
import 'dart:ui';

import '../../../persona/appearance/appearance_state.dart';

/// 一张脸的全部可变参数；四维都在 [-1, 1] 或 [0, 1] 内，可线性插值。
class FaceParams {
  const FaceParams({
    required this.eyeOpenness,
    required this.browAngle,
    required this.mouthCurve,
    required this.blushOpacity,
  });

  /// 眼睛开合 [0, 1]：0 全闭（弧线），1 圆睁。
  final double eyeOpenness;

  /// 眉毛角度 [-1, 1]：负 = 眉梢上挑（惊喜），正 = 内压（严肃）。
  final double browAngle;

  /// 嘴形弧度 [-1, 1]：正 = 上弯（笑），0 = 平，负 = 下撇。
  final double mouthCurve;

  /// 腮红透明度 [0, 1]：0 不画。
  final double blushOpacity;

  @override
  bool operator ==(Object other) =>
      other is FaceParams &&
      other.eyeOpenness == eyeOpenness &&
      other.browAngle == browAngle &&
      other.mouthCurve == mouthCurve &&
      other.blushOpacity == blushOpacity;

  @override
  int get hashCode =>
      Object.hash(eyeOpenness, browAngle, mouthCurve, blushOpacity);
}

/// 表情集四态 → 参数（推演只改表情集，渲染端查表即可，无自由数值）。
const Map<AppearanceExpressionSet, FaceParams> expressionFaces = {
  // 柔和：半睁 + 浅笑，中性基线。
  AppearanceExpressionSet.soft: FaceParams(
    eyeOpenness: 0.65,
    browAngle: 0,
    mouthCurve: 0.35,
    blushOpacity: 0.1,
  ),
  // 明亮：圆睁 + 上挑眉 + 咧嘴。
  AppearanceExpressionSet.bright: FaceParams(
    eyeOpenness: 1,
    browAngle: -0.2,
    mouthCurve: 0.9,
    blushOpacity: 0.15,
  ),
  // 冷静：眯眼 + 微压眉 + 平嘴。
  AppearanceExpressionSet.cool: FaceParams(
    eyeOpenness: 0.3,
    browAngle: 0.15,
    mouthCurve: 0,
    blushOpacity: 0,
  ),
  // 害羞：垂眼 + 小嘴 + 重腮红。
  AppearanceExpressionSet.shy: FaceParams(
    eyeOpenness: 0.45,
    browAngle: 0,
    mouthCurve: 0.2,
    blushOpacity: 0.6,
  ),
};

/// 参数插值：表情切换（如推演后过渡）在参数空间连续，不跳变。
/// 端点短路：浮点上 a+(b-a)*1 不恒等于 b，动画首末帧要精确还原。
FaceParams lerpFaceParams(FaceParams a, FaceParams b, double t) {
  if (t <= 0) return a;
  if (t >= 1) return b;
  return FaceParams(
    eyeOpenness: a.eyeOpenness + (b.eyeOpenness - a.eyeOpenness) * t,
    browAngle: a.browAngle + (b.browAngle - a.browAngle) * t,
    mouthCurve: a.mouthCurve + (b.mouthCurve - a.mouthCurve) * t,
    blushOpacity: a.blushOpacity + (b.blushOpacity - a.blushOpacity) * t,
  );
}

/// 画一张参数化脸。
///
/// [base] = true 画圆脸底（气泡配图独立成图用）；false 只画五官
/// （预览/宠物本体把五官画在自己的身体上）。
void paintFace(Canvas canvas, Size size, FaceParams face, {bool base = true}) {
  if (size.isEmpty) return;
  final center = Offset(size.width / 2, size.height / 2);
  final radius = size.shortestSide / 2;

  if (base) {
    canvas.drawCircle(
      center,
      radius,
      Paint()..color = const Color(0xFFF7EFE3),
    );
  }
  // 五官占脸的固定比例区：眼在中线略上，嘴在下三分之一。
  final eyeY = center.dy - radius * 0.18;
  final eyeDx = radius * 0.34;
  _paintEyes(canvas, center, eyeY, eyeDx, radius, face);
  _paintBrows(canvas, center, eyeY, eyeDx, radius, face);
  _paintMouth(canvas, center, radius, face);
  _paintBlush(canvas, center, eyeY, eyeDx, radius, face);
}

void _paintEyes(
  Canvas canvas,
  Offset center,
  double eyeY,
  double eyeDx,
  double radius,
  FaceParams face,
) {
  final ink = Paint()..color = const Color(0xFF2A3442);
  final eyeRadius = radius * 0.11;
  // 开合映射为竖向半径：低于阈值画弧线（闭眼），否则椭圆。
  final openness = face.eyeOpenness.clamp(0.0, 1.0);
  if (openness < 0.15) {
    final line = Paint()
      ..color = const Color(0xFF2A3442)
      ..strokeWidth = radius * 0.03
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (final dx in [-eyeDx, eyeDx]) {
      canvas.drawLine(
        Offset(center.dx + dx - eyeRadius, eyeY),
        Offset(center.dx + dx + eyeRadius, eyeY),
        line,
      );
    }
    return;
  }
  for (final dx in [-eyeDx, eyeDx]) {
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(center.dx + dx, eyeY),
        width: eyeRadius * 2,
        height: eyeRadius * 2 * openness,
      ),
      ink,
    );
    // 高光让眼睛有神：随开合缩小，闭眼时不画。
    final glint = openness * eyeRadius * 0.3;
    if (glint > radius * 0.02) {
      canvas.drawCircle(
        Offset(center.dx + dx - eyeRadius * 0.3, eyeY - glint),
        glint,
        Paint()..color = const Color(0xE6FFFFFF),
      );
    }
  }
}

void _paintBrows(
  Canvas canvas,
  Offset center,
  double eyeY,
  double eyeDx,
  double radius,
  FaceParams face,
) {
  final brow = Paint()
    ..color = const Color(0xFF3B4A5F)
    ..strokeWidth = radius * 0.035
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;
  // 角度：绕眉中点旋转，幅度上限 0.5 弧度（约 29°，够挑/皱但不夸张）。
  final angle = face.browAngle.clamp(-1.0, 1.0) * 0.5;
  final browY = eyeY - radius * 0.26;
  final half = radius * 0.14;
  for (final dx in [-eyeDx, eyeDx]) {
    // 左眉与右眉对称：同角度值在两张脸上语义一致（挑/皱），方向镜像。
    final mirror = dx < 0 ? 1.0 : -1.0;
    final mid = Offset(center.dx + dx, browY);
    final dxUnit = mirror * half * -1;
    final dyUnit = half * math.tan(angle);
    // tan 在 ±0.5 弧度内近似线性，直接连线即可。
    canvas.drawLine(
      Offset(mid.dx - dxUnit, mid.dy - dyUnit),
      Offset(mid.dx + dxUnit, mid.dy + dyUnit),
      brow,
    );
  }
}

void _paintMouth(
  Canvas canvas,
  Offset center,
  double radius,
  FaceParams face,
) {
  final paint = Paint()
    ..color = const Color(0xFF2A3442)
    ..strokeWidth = radius * 0.035
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;
  final mouthY = center.dy + radius * 0.34;
  final half = radius * 0.2;
  // 嘴形弧度：一条二次曲线，控制点纵向偏移决定上弯/平/下撇。
  final curve = face.mouthCurve.clamp(-1.0, 1.0) * radius * 0.18;
  final path = Path()
    ..moveTo(center.dx - half, mouthY)
    ..quadraticBezierTo(center.dx, mouthY - curve, center.dx + half, mouthY);
  canvas.drawPath(path, paint);
}

void _paintBlush(
  Canvas canvas,
  Offset center,
  double eyeY,
  double eyeDx,
  double radius,
  FaceParams face,
) {
  final opacity = face.blushOpacity.clamp(0.0, 1.0);
  if (opacity <= 0.02) return;
  final blush = Paint()..color = Color.fromRGBO(255, 123, 138, opacity);
  final blushY = eyeY + radius * 0.22;
  for (final dx in [-eyeDx * 1.5, eyeDx * 1.5]) {
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(center.dx + dx, blushY),
        width: radius * 0.22,
        height: radius * 0.13,
      ),
      blush,
    );
  }
}
