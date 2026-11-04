/// 装扮图层（paperdoll 的程序化落地）：body 之上、accessory 之下。
///
/// 为什么不用素材帧：帧动画是整张成品 spritesheet（110 个动画 × 全帧位），
/// 每套装扮做整帧覆盖成本不可行；装饰层程序化绘制与帧位天然对齐
/// （同一坐标系、同一命中区、不扩大窗口命中椭圆），
/// 未来接入真素材时在此加 loader 分支即可，调用方接口不变。
library;

import 'dart:ui';

import '../../../persona/appearance/appearance_state.dart' show trendOutfitPrefix;

/// 趋势装扮的动态配色注册表：白名单之外，trend- 装扮由内核在
/// 接受 LLM 提案时注册；已接受的配色随治理状态落盘、内核启动时
/// 回放注册（冻结形象时换装轨道不回落，图层不能只活在内存里）。
final Map<String, (Color, Color)> _trendColors = {};

/// 注册趋势装扮配色（0xAARRGGBB，来自已过校验的提案）；同主题幂等覆盖。
void registerTrendColors(String outfit, int main, int trim) {
  _trendColors[outfit] = (Color(main), Color(trim));
}

/// 测试隔离用：清空动态注册表。
void resetTrendColors() => _trendColors.clear();

/// 该装扮是否有可见图层（设置页预览与测试用）。
bool wardrobeKnows(String outfit) => switch (outfit) {
  'winter' ||
  'newyear' ||
  'midautumn' ||
  'halloween' ||
  'christmas' ||
  'rain' ||
  'snow' ||
  'sunny' => true,
  // 只认受控前缀：内置名永远不可能被注册表覆盖。
  _ => outfit.startsWith(trendOutfitPrefix) && _trendColors.containsKey(outfit),
};

/// 画装扮：未知装扮静默不画（白名单扩张先于绘制器时走安全侧）。
///
/// 坐标系与 pet_view 的配饰层一致：宠物矩形内的比例坐标；
/// home 与春/夏/秋无叠加（默认形态即居家，冬与节令才有衣物）。
void paintOutfit(Canvas canvas, Size size, String outfit) {
  // 统一形状是「围巾」：主色环 + 垂穗，颜色随装扮区分。
  final (main, trim) = scarfColorsOf(outfit);
  if (main == null || trim == null) return;

  final band = Paint()..color = main;
  final stroke = Paint()..color = trim;
  // 环身横带：略低于 accessory.scarf 的位置（装扮在体、配饰在外）。
  final center = Offset(size.width * 0.52, size.height * 0.72);
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: center,
        width: size.width * 0.4,
        height: size.height * 0.09,
      ),
      Radius.circular(size.width * 0.04),
    ),
    band,
  );
  // 垂穗：从环带前侧垂下一段短带，端头圆角收边。
  final tailRect = Rect.fromCenter(
    center: Offset(size.width * 0.66, size.height * 0.8),
    width: size.width * 0.1,
    height: size.height * 0.16,
  );
  canvas.drawRRect(
    RRect.fromRectAndRadius(tailRect, Radius.circular(size.width * 0.04)),
    stroke,
  );
}

/// 装扮的围巾配色；无图层的装扮返回 (null, null)。
(Color?, Color?) scarfColorsOf(String outfit) => switch (outfit) {
  // 冬：奶白毛线（默认应季装）。
  'winter' => (const Color(0xFFF3E9DC), const Color(0xFFD9C7B2)),
  // 春节：中国红 + 金穗。
  'newyear' => (const Color(0xFFE23E3E), const Color(0xFFF2C14E)),
  // 中秋：暖月黄 + 桂木棕。
  'midautumn' => (const Color(0xFFF6C453), const Color(0xFF9C6B30)),
  // 万圣夜：南瓜橙 + 暗紫。
  'halloween' => (const Color(0xFFF2811D), const Color(0xFF6A3FA0)),
  // 圣诞：松绿 + 圣诞红。
  'christmas' => (const Color(0xFF2E7D52), const Color(0xFFD64545)),
  // 雨具（天气装扮）：明黄雨衣 + 靛蓝垂穗——雨天识别度最高的配色。
  'rain' => (const Color(0xFFF2C94C), const Color(0xFF3D5A80)),
  // 雪装（天气装扮）：冰蓝 + 雪白，与冬季默认装的奶白区分开。
  'snow' => (const Color(0xFFA8DADC), const Color(0xFFFFFFFF)),
  // 晴日装（天气装扮）：向日葵黄 + 天蓝穗。
  'sunny' => (const Color(0xFFF4A261), const Color(0xFF6FC2D0)),
  // 趋势装扮：注册表配色（未注册 = 没画，静默跳过）。
  _ => _trendColors[outfit] ?? (null, null),
};
