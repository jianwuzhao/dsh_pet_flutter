/// 命中区判定：窗口是全屏透明的，只有“宠物身体 / 气泡 / 菜单”区域接收鼠标。
///
/// 上游用矩形包围盒再收一圈；这里用椭圆近似身体（素材四周有大量透明留白，
/// 纯矩形会让用户点到空气也算点中宠物）。
library;

import 'dart:ui';

/// 光标是否落在宠物身体上。[body] 为宠物动画的绘制区域（非窗口）。
bool hitsPetBody(Offset cursor, Rect body) {
  if (!body.contains(cursor)) return false;
  final rx = body.width / 2;
  final ry = body.height / 2;
  if (rx <= 0 || ry <= 0) return false;
  final dx = (cursor.dx - body.center.dx) / rx;
  final dy = (cursor.dy - body.center.dy) / ry;
  return dx * dx + dy * dy <= 1.0;
}
