/// 桌宠浮层定位：菜单、气泡、面板都必须贴着宠物、又必须留在它当前的那块屏里。
///
/// 为什么不直接 `Positioned`：浮层尺寸由内容决定（菜单行数、气泡文本长度、
/// 设置页字段多少都会变），写死宽高再 clamp 必然在某个尺寸下算错。这里让
/// Flutter 先量出子组件真实尺寸，再按屏幕边界决定放在上方 / 下方 / 翻转。
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

enum FlyoutPlacement {
  /// 以 [FlyoutPlacement] 的 anchor（右键位置）为左上角，空间不足时向左/上翻转。
  pointer,

  /// 面板：默认在宠物上方居中，顶部放不下就放到宠物下方。
  panel,

  /// 气泡：在宠物上方。
  above,

  /// 气泡：在宠物下方（宠物贴着屏幕顶部时）。
  below,
}

class PetFlyoutLayout extends SingleChildLayoutDelegate {
  const PetFlyoutLayout({
    required this.screen,
    required this.pet,
    required this.placement,
    this.anchor,
    this.padding = 10,
    this.gap = 12,
  });

  /// 宠物当前所在屏幕的可见区（窗口本地坐标）。
  final Rect screen;

  /// 宠物身体矩形（窗口本地坐标）。
  final Rect pet;

  final FlyoutPlacement placement;

  /// 右键位置；只有 [FlyoutPlacement.pointer] 用得到。
  final Offset? anchor;

  /// 浮层与屏幕边缘的安全距离。
  final double padding;

  /// 浮层与宠物之间的间距。
  final double gap;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final maxWidth = math.max(
      0.0,
      math.min(constraints.maxWidth, screen.width - padding * 2),
    );
    final maxHeight = math.max(
      0.0,
      math.min(constraints.maxHeight, screen.height - padding * 2),
    );
    return BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final bounds = Rect.fromLTWH(
      screen.left + padding,
      screen.top + padding,
      math.max(0.0, screen.width - padding * 2),
      math.max(0.0, screen.height - padding * 2),
    );
    // 子组件比安全区还大（极小屏/极长菜单）时贴左上角，不再做负坐标翻转。
    if (childSize.width >= bounds.width || childSize.height >= bounds.height) {
      return bounds.topLeft;
    }

    var x = pet.center.dx - childSize.width / 2;
    var y = pet.top - gap - childSize.height;
    switch (placement) {
      case FlyoutPlacement.pointer:
        final point = anchor ?? pet.center;
        x = point.dx;
        y = point.dy;
        // 菜单默认向右下展开；会出屏时整体翻到点击点左侧/上方。
        if (x + childSize.width > bounds.right) x = point.dx - childSize.width;
        if (y + childSize.height > bounds.bottom) {
          y = point.dy - childSize.height;
        }
        break;
      case FlyoutPlacement.panel:
        // 优先在宠物上方展开，头顶空间不足时落到脚下。
        if (y < bounds.top) y = pet.bottom + gap;
        break;
      case FlyoutPlacement.above:
        break;
      case FlyoutPlacement.below:
        y = pet.bottom + gap;
        break;
    }

    x = x
        .clamp(
          bounds.left,
          math.max(bounds.left, bounds.right - childSize.width),
        )
        .toDouble();
    y = y
        .clamp(
          bounds.top,
          math.max(bounds.top, bounds.bottom - childSize.height),
        )
        .toDouble();
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(covariant PetFlyoutLayout oldDelegate) =>
      screen != oldDelegate.screen ||
      pet != oldDelegate.pet ||
      placement != oldDelegate.placement ||
      anchor != oldDelegate.anchor ||
      padding != oldDelegate.padding ||
      gap != oldDelegate.gap;
}
