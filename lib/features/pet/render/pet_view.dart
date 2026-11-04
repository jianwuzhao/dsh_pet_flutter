/// 宠物绘制：把当前帧（以及淡出中的旧帧）画进宠物矩形，支持镜像与交叉淡入。
///
/// 只做“把 ui.Image 画出来”，选择哪一帧、何时切换都在 PetController。
/// 配色与装扮都来自形象状态、走同一条保明暗色偏矩阵（保留明暗与轮廓）：
/// 配色是人格演化级、装扮是情境换装级，两级折叠成单矩阵一次滤镜完成。
/// 默认海蓝 + 居家装扮不套滤镜，保持原画。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../persona/appearance/appearance_state.dart';
import '../pet_controller.dart';
import 'wardrobe.dart';

class PetView extends StatelessWidget {
  const PetView({
    super.key,
    required this.controller,
    this.palette = AppearancePalette.blue,
    this.accessory = AppearanceAccessory.none,
    this.outfit = defaultOutfit,
  });

  final PetController controller;

  /// 当前配色；blue 为原画，其余色板按固定比例混入。
  final AppearancePalette palette;

  /// 配饰叠加：只画在宠物矩形内，不扩大窗口命中区。
  final AppearanceAccessory accessory;

  /// 装扮叠加（P2-2）：主题色经矩阵驱动底稿，不画几何色块。
  final String outfit;

  /// 两级主题色偏矩阵：配色（人格演化级）先上、装扮（情境换装级）后上。
  ///
  /// 输出 = (1-m)·原色 + m·亮度·主题色，保留明暗与轮廓；默认海蓝 +
  /// 无配色装扮不混色，只保留透明度衰减。公开为纯函数：渲染与像素级
  /// 测试共用同一份矩阵，测试不再需要拼装整个 PetView。
  static List<double> colorMatrixFor(
    AppearancePalette palette,
    String outfit,
    double opacity,
  ) {
    const mix = 0.55;
    final alpha = opacity.clamp(0.0, 1.0);
    // blue 是素材原色：不混色；装扮级不受配色是否原色影响。
    final base = _tintMatrix(
      _paletteTint(palette),
      palette == AppearancePalette.blue ? 0.0 : mix,
      alpha,
    );
    final tint = outfitTintOf(outfit);
    if (tint == null) return base;
    // 装扮级叠加在配色级之后、透明度交给 base 的 alpha 行：
    // 组合后 alpha = 1·alpha，交叉淡入淡出不受换装影响。
    // Color.r/g/b 即归一化 0-1 通道值，直接作矩阵 tint。
    return _compose(_tintMatrix((tint.r, tint.g, tint.b), mix, 1.0), base);
  }

  static (double, double, double) _paletteTint(AppearancePalette palette) =>
      switch (palette) {
        AppearancePalette.blue => const (0.30, 0.55, 0.96),
        AppearancePalette.green => const (0.27, 0.75, 0.54),
        AppearancePalette.orange => const (0.96, 0.60, 0.30),
        AppearancePalette.purple => const (0.60, 0.49, 0.95),
        AppearancePalette.gray => const (0.62, 0.64, 0.67),
      };

  /// 单级主题矩阵：输出 = (1-m)·原色 + m·亮度·tint，alpha 行独立衰减。
  ///
  /// 用矩阵而不是 BlendMode.hue：非可分离混合在部分渲染后端不可靠，
  /// 矩阵在 Skia/Impeller 上行为一致，也不依赖运行时分支。
  static List<double> _tintMatrix(
    (double, double, double) tint,
    double m,
    double alpha,
  ) {
    const lr = 0.2126;
    const lg = 0.7152;
    const lb = 0.0722;
    return [
      (1 - m) + m * lr * tint.$1,
      m * lg * tint.$1,
      m * lb * tint.$1,
      0,
      0,
      m * lr * tint.$2,
      (1 - m) + m * lg * tint.$2,
      m * lb * tint.$2,
      0,
      0,
      m * lr * tint.$3,
      m * lg * tint.$3,
      (1 - m) + m * lb * tint.$3,
      0,
      0,
      0,
      0,
      0,
      alpha,
      0,
    ];
  }

  /// 4×5 仿射矩阵合成（below 先应用、above 后应用）。
  ///
  /// 两次保明暗混色折叠为单矩阵、一次滤镜完成：多画一遍中间纹理
  /// 既费一次全帧绘制，交叉淡入的两帧透明度也更难对齐。
  static List<double> _compose(List<double> above, List<double> below) {
    final out = List<double>.filled(20, 0.0);
    for (var row = 0; row < 4; row++) {
      for (var col = 0; col < 4; col++) {
        var sum = 0.0;
        for (var k = 0; k < 4; k++) {
          sum += above[row * 5 + k] * below[k * 5 + col];
        }
        out[row * 5 + col] = sum;
      }
      // 平移列：above 自身的偏移 + above 对 below 偏移的线性组合。
      var offset = above[row * 5 + 4];
      for (var k = 0; k < 4; k++) {
        offset += above[row * 5 + k] * below[k * 5 + 4];
      }
      out[row * 5 + 4] = offset;
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _PetPainter(controller, palette, accessory, outfit),
      size: controller.petSize,
    );
  }
}

class _PetPainter extends CustomPainter {
  _PetPainter(this.controller, this.palette, this.accessory, this.outfit)
    : super(repaint: controller.repaint);

  final PetController controller;
  final AppearancePalette palette;
  final AppearanceAccessory accessory;
  final String outfit;

  @override
  void paint(Canvas canvas, Size size) {
    final progress = controller.fadeProgress;
    final outgoing = controller.fadeFrom;
    if (outgoing != null) _paintFrame(canvas, outgoing, size, 1 - progress);

    final image = controller.player?.image;
    if (image != null) _paintFrame(canvas, image, size, progress);
    // 装扮不再画叠加层（平面色块与成品立绘风格互斥），主题色已并入
    // _paintFrame 的矩阵：底稿自己换色，只剩配饰（在外）一层叠加。
    _paintAccessory(canvas, size);
  }

  /// 配饰是程序化叠加：不改素材、不改命中区，只做可见表达。
  void _paintAccessory(Canvas canvas, Size size) {
    switch (accessory) {
      case AppearanceAccessory.none:
        return;
      case AppearanceAccessory.scarf:
        final scarf = Paint()..color = const Color(0xFFE05A5A);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset(size.width * 0.52, size.height * 0.78),
              width: size.width * 0.36,
              height: size.height * 0.07,
            ),
            Radius.circular(size.width * 0.03),
          ),
          scarf,
        );
        canvas.drawCircle(
          Offset(size.width * 0.65, size.height * 0.83),
          size.width * 0.025,
          scarf,
        );
        break;
      case AppearanceAccessory.glasses:
        final rim = Paint()
          ..color = const Color(0xFF3B4A5F)
          ..style = PaintingStyle.stroke
          ..strokeWidth = size.width * 0.008;
        final eyeY = size.height * 0.42;
        final left = Offset(size.width * 0.44, eyeY);
        final right = Offset(size.width * 0.62, eyeY);
        final radius = size.width * 0.04;
        canvas.drawCircle(left, radius, rim);
        canvas.drawCircle(right, radius, rim);
        canvas.drawLine(
          Offset(left.dx + radius, eyeY),
          Offset(right.dx - radius, eyeY),
          rim,
        );
        break;
      case AppearanceAccessory.hat:
        final hat = Paint()..color = const Color(0xFF4E6E8E);
        canvas.drawRect(
          Rect.fromCenter(
            center: Offset(size.width * 0.52, size.height * 0.2),
            width: size.width * 0.2,
            height: size.height * 0.1,
          ),
          hat,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset(size.width * 0.52, size.height * 0.26),
              width: size.width * 0.3,
              height: size.height * 0.02,
            ),
            Radius.circular(size.width * 0.01),
          ),
          hat,
        );
        break;
    }
  }

  void _paintFrame(Canvas canvas, ui.Image image, Size size, double opacity) {
    if (opacity <= 0.01 || size.isEmpty) return;
    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      // 两级主题色偏矩阵同时承担透明度衰减：一次滤镜完成全部。
      ..colorFilter = ColorFilter.matrix(
        PetView.colorMatrixFor(palette, outfit, opacity),
      );

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

  @override
  bool shouldRepaint(covariant _PetPainter oldDelegate) =>
      oldDelegate.palette != palette ||
      oldDelegate.accessory != accessory ||
      oldDelegate.outfit != outfit;
}
