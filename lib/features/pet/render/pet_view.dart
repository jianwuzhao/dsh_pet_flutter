/// 宠物绘制：把当前帧（以及淡出中的旧帧）画进宠物矩形，支持镜像与交叉淡入。
///
/// 只做“把 ui.Image 画出来”，选择哪一帧、何时切换都在 PetController。
/// 可选 rig 按规范坐标合成槽位；未配置时继续播放素材帧。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../pet_controller.dart';

class PetView extends StatelessWidget {
  const PetView({super.key, required this.controller});

  final PetController controller;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _PetPainter(controller),
      size: controller.petSize,
    );
  }
}

class _PetPainter extends CustomPainter {
  _PetPainter(this.controller) : super(repaint: controller.repaint);

  final PetController controller;

  @override
  void paint(Canvas canvas, Size size) {
    final rig = controller.rigPlayer;
    if (rig != null) {
      canvas.save();
      if (controller.facing < 0) {
        canvas.translate(size.width, 0);
        canvas.scale(-1, 1);
      }
      rig.paint(canvas, size);
      canvas.restore();
      return;
    }
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
      // 交叉淡入的透明度走画笔颜色调制 alpha，不用滤镜：帧内容保持原样。
      ..color = const Color(0xFFFFFFFF).withValues(alpha: opacity);

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
  bool shouldRepaint(covariant _PetPainter oldDelegate) => false;
}
