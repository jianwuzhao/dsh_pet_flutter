/// 生成式头像里程碑（P2-5）：form 晋升纪念头像，DiceBear 等价的
/// 程序化路线（D3 决策：离线优先，外部 API 二期再议）。
///
/// DiceBear 本体是「种子 → 参数化拼装 SVG」；桌面端无成熟离线包，
/// 与装扮/表情同管线裁剪：种子 = (form, palette, revision, 晋升日期)，
/// 程序化绘制纪念头像，同输入必得同图（可复现、可测试）。
/// 治理：默认不出入口（只在晋升后出现）+ 每月限 1 次。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import '../../core/paths/app_paths.dart';
import '../../core/result.dart';
import 'appearance_state.dart';

/// 月限治理状态（与趋势 gate 同思路：单独落盘，不进形象版本历史）。
class AvatarMementoGate {
  const AvatarMementoGate({this.lastGeneratedMonth});

  /// 上次生成的月键（yyyy-MM）；同月内不再生成。
  final String? lastGeneratedMonth;

  AvatarMementoGate copyWith({String? lastGeneratedMonth}) =>
      AvatarMementoGate(lastGeneratedMonth: lastGeneratedMonth ?? this.lastGeneratedMonth);

  Map<String, dynamic> toJson() => {'month': lastGeneratedMonth};

  factory AvatarMementoGate.fromJson(Map<String, dynamic> json) =>
      AvatarMementoGate(lastGeneratedMonth: json['month'] as String?);
}

/// 月键：跨月自动翻篇，月初即可再生成。
String mementoMonthKey(DateTime now) =>
    '${now.year}-${now.month.toString().padLeft(2, '0')}';

class AvatarMementoStore {
  AvatarMementoStore({Directory? directory})
    : _directory = directory ?? AppPaths.profileDir;

  final Directory _directory;

  File get _file =>
      File('${_directory.path}${Platform.pathSeparator}avatar_memento.json');

  AvatarMementoGate load() {
    try {
      final file = _file;
      if (!file.existsSync()) return const AvatarMementoGate();
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map<String, dynamic>) return const AvatarMementoGate();
      return AvatarMementoGate.fromJson(raw);
    } on Object {
      // 治理状态可丢：损坏按空 gate（最多多生成一张，无损降级）。
      return const AvatarMementoGate();
    }
  }

  Result<void> save(AvatarMementoGate gate) {
    try {
      if (!_directory.existsSync()) _directory.createSync(recursive: true);
      final tmp = File('${_file.path}.tmp');
      tmp.writeAsStringSync(jsonEncode(gate.toJson()), flush: true);
      tmp.renameSync(_file.path);
      return const Success(null);
    } on Object catch (error) {
      return Failure('memento.write-failed', '纪念头像治理状态写入失败：$error');
    }
  }

  /// 纪念头像 PNG 的落点：月限保证月内唯一，文件名按月键不覆盖。
  File pngFileFor(String month) =>
      File('${_directory.path}${Platform.pathSeparator}memento_$month.png');
}

/// 调色板 → (身体色, 腹色)：纪念头像自含映射，与设置页预览各自演化。
(ui.Color, ui.Color) _paletteColors(AppearancePalette palette) => switch (palette) {
  AppearancePalette.blue => (
    const ui.Color(0xFF6FA8DC),
    const ui.Color(0xFFD7EBF7),
  ),
  AppearancePalette.green => (
    const ui.Color(0xFF8CD1A5),
    const ui.Color(0xFFE4F5E9),
  ),
  AppearancePalette.orange => (
    const ui.Color(0xFFF2B880),
    const ui.Color(0xFFFBE8D3),
  ),
  AppearancePalette.purple => (
    const ui.Color(0xFFB39DDB),
    const ui.Color(0xFFEDE7F6),
  ),
  AppearancePalette.gray => (
    const ui.Color(0xFFB0BEC5),
    const ui.Color(0xFFECEFF1),
  ),
};

/// 画晋升纪念头像：渐变底 + form 剪影 + 星点装饰 + 晋升日期。
///
/// 全部由 (form, palette, revision, promotedAt) 决定——同一份档案
/// 重画得到同一张图，这是「DiceBear 式种子生成」的离线等价物。
void paintMemento(
  ui.Canvas canvas,
  ui.Size size,
  AppearanceState state,
  DateTime promotedAt,
) {
  if (size.isEmpty) return;
  final center = ui.Offset(size.width / 2, size.height / 2);
  final radius = size.shortestSide / 2;
  final (body, belly) = _paletteColors(state.palette);

  // 底：palette 主色的径向渐变（纪念感来自光晕而非平面色）。
  canvas.drawRect(
    ui.Offset.zero & size,
    ui.Paint()
      ..shader = ui.Gradient.radial(
        center,
        radius,
        [ui.Color.lerp(body, ui.Color(0xFF101418), 0.55)!, body],
      ),
  );

  // 星点：revision 决定数量与角度（同 revision 同图，晋升次数越多越热闹）。
  final starCount = 3 + (state.revision % 4);
  final star = ui.Paint()..color = const ui.Color(0xCCFFFFFF);
  for (var i = 0; i < starCount; i++) {
    final angle = i * 2.399963; // 黄金角：固定序列，星点自然散开。
    final distance = radius * (0.62 + (i % 3) * 0.11);
    canvas.drawCircle(
      ui.Offset(
        center.dx + distance * math.cos(angle),
        center.dy + distance * 0.72 * math.sin(angle),
      ),
      size.shortestSide * 0.012,
      star,
    );
  }

  // 中央 form 剪影：宽高比按体型走（与预览的 formFactor 语义一致）。
  final (formW, formH) = switch (state.form) {
    AppearanceForm.slim => (0.66, 1.0),
    AppearanceForm.round => (1.0, 0.92),
    AppearanceForm.chubby => (1.08, 0.88),
    AppearanceForm.tall => (0.8, 1.1),
  };
  final silhouette = ui.Rect.fromCenter(
    center: center,
    width: radius * 1.05 * formW,
    height: radius * 1.05 * formH,
  );
  canvas.drawOval(
    silhouette,
    ui.Paint()
      ..shader = ui.Gradient.linear(
        ui.Offset(silhouette.left, silhouette.top),
        ui.Offset(silhouette.right, silhouette.bottom),
        [ui.Color.lerp(body, const ui.Color(0xFFFFFFFF), 0.28)!, body],
      ),
  );
  canvas.drawOval(
    ui.Rect.fromCenter(
      center: ui.Offset(center.dx, center.dy + silhouette.height * 0.12),
      width: silhouette.width * 0.62,
      height: silhouette.height * 0.5,
    ),
    ui.Paint()..color = belly,
  );

  // 日期条：晋升日期是这张图的「为什么」。
  final label = '晋升纪念  ${promotedAt.year}-${promotedAt.month.toString().padLeft(2, '0')}-${promotedAt.day.toString().padLeft(2, '0')}';
  final paragraph =
      ui.ParagraphBuilder(
        ui.ParagraphStyle(textAlign: ui.TextAlign.center, maxLines: 1),
      )
        ..pushStyle(
          ui.TextStyle(
            color: const ui.Color(0xFFF3EFE6),
            fontSize: size.shortestSide * 0.048,
          ),
        )
        ..addText(label);
  final laid = paragraph.build()
    ..layout(
      ui.ParagraphConstraints(width: size.width * 0.9),
    );
  canvas.drawRRect(
    ui.RRect.fromRectAndRadius(
      ui.Rect.fromCenter(
        center: ui.Offset(center.dx, size.height - radius * 0.28),
        width: size.width * 0.84,
        height: size.shortestSide * 0.1,
      ),
      ui.Radius.circular(size.shortestSide * 0.05),
    ),
    ui.Paint()..color = const ui.Color(0x66000000),
  );
  canvas.drawParagraph(
    laid,
    ui.Offset(
      center.dx - laid.maxIntrinsicWidth / 2,
      size.height - radius * 0.28 - laid.height / 2,
    ),
  );
}
