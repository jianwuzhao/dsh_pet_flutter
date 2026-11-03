/// 宠物绘制：把当前帧（以及淡出中的旧帧）画进宠物矩形，支持镜像与交叉淡入。
///
/// 只做“把 ui.Image 画出来”，选择哪一帧、何时切换都在 PetController。
/// 配色来自形象状态：用确定性色偏矩阵（保留明暗与轮廓），默认海蓝不套滤镜。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../persona/appearance/appearance_state.dart';
import '../pet_controller.dart';

class PetView extends StatelessWidget {
  const PetView({
    super.key,
    required this.controller,
    this.palette = AppearancePalette.blue,
  });

  final PetController controller;

  /// 当前配色；blue 为原画，其余色板按固定比例混入。
  final AppearancePalette palette;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _PetPainter(controller, palette),
      size: controller.petSize,
    );
  }
}

class _PetPainter extends CustomPainter {
  _PetPainter(this.controller, this.palette) : super(repaint: controller.repaint);

  final PetController controller;
  final AppearancePalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    final progress = controller.fadeProgress;
    final outgoing = controller.fadeFrom;
    if (outgoing != null) _paintFrame(canvas, outgoing, size, 1 - progress);

    final image = controller.player?.image;
    if (image != null) _paintFrame(canvas, image, size, progress);
  }

  void _paintFrame(Canvas canvas, ui.Image image, Size size, double opacity) {
    if (opacity <= 0.01 || size.isEmpty) return;
    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      // 色偏矩阵同时承担透明度衰减：一次滤镜完成配色与淡入。
      ..colorFilter = ColorFilter.matrix(_matrixFor(palette, opacity));

    canvas.save();
    if (controller.facing < 0) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      paint,
    );
    canvas.restore();
  }

  /// 输出 = (1-f)·原色 + f·亮度·色板色；默认海蓝保持原画。
  ///
  /// 用矩阵而不是 BlendMode.hue：非可分离混合在部分渲染后端不可靠，
  /// 矩阵在 Skia/Impeller 上行为一致，也不依赖运行时分支。
  static List<double> _matrixFor(AppearancePalette palette, double opacity) {
    const f = 0.55;
    const lr = 0.2126;
    const lg = 0.7152;
    const lb = 0.0722;
    final tint = switch (palette) {
      AppearancePalette.blue => const (0.30, 0.55, 0.96),
      AppearancePalette.green => const (0.27, 0.75, 0.54),
      AppearancePalette.orange => const (0.96, 0.60, 0.30),
      AppearancePalette.purple => const (0.60, 0.49, 0.95),
      AppearancePalette.gray => const (0.62, 0.64, 0.67),
    };
    // blue 是素材原色：不做混色，只保留透明度。
    final mix = palette == AppearancePalette.blue ? 0.0 : f;
    final alpha = opacity.clamp(0.0, 1.0);
    return [
      (1 - mix) + mix * lr * tint.$1,
      mix * lg * tint.$1,
      mix * lb * tint.$1,
      0,
      0,
      mix * lr * tint.$2,
      (1 - mix) + mix * lg * tint.$2,
      mix * lb * tint.$2,
      0,
      0,
      mix * lr * tint.$3,
      mix * lg * tint.$3,
      (1 - mix) + mix * lb * tint.$3,
      0,
      0,
      0,
      0,
      0,
      alpha,
      0,
    ];
  }

  @override
  bool shouldRepaint(covariant _PetPainter oldDelegate) =>
      oldDelegate.palette != palette;
}
