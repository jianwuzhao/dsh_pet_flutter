/// 装扮配色（paperdoll 的程序化落地）：装扮 = 底层形象整体换主题色。
///
/// 为什么不画叠加图层：底图是带明暗层次的成品立绘，任何程序化
/// 平面色块盖上去都读作 UI 元件而不是衣服（线条、比例与底稿风格
/// 互斥）。保明暗配色矩阵让底稿自己「换装」：轮廓、褶皱、阴影全
/// 保留，只换主题色——与配色演化同一管线，感知一致。
/// 未来接入真装扮素材帧时在此加 loader 分支即可，调用方接口不变。
library;

import 'dart:ui';

import '../../../persona/appearance/appearance_state.dart' show trendOutfitPrefix;

/// 趋势装扮的动态配色注册表：白名单之外，trend- 装扮由内核在
/// 接受 LLM 提案时注册；已接受的配色随治理状态落盘、内核启动时
/// 回放注册（冻结形象时换装轨道不回落，配色不能只活在内存里）。
final Map<String, (Color, Color)> _trendColors = {};

/// 注册趋势装扮配色（0xAARRGGBB，来自已过校验的提案）；同主题幂等覆盖。
void registerTrendColors(String outfit, int main, int trim) {
  _trendColors[outfit] = (Color(main), Color(trim));
}

/// 测试隔离用：清空动态注册表。
void resetTrendColors() => _trendColors.clear();

/// 装扮主题色；无配色的装扮（居家/春夏秋默认形态、未注册趋势）
/// 返回 null——底稿保持原样，安全侧。
Color? outfitTintOf(String outfit) => switch (outfit) {
  // 冬：奶白毛线（默认应季装）。
  'winter' => const Color(0xFFF3E9DC),
  // 春节：中国红。
  'newyear' => const Color(0xFFE23E3E),
  // 中秋：暖月黄。
  'midautumn' => const Color(0xFFF6C453),
  // 万圣夜：南瓜橙。
  'halloween' => const Color(0xFFF2811D),
  // 圣诞：松绿。
  'christmas' => const Color(0xFF2E7D52),
  // 雨具（天气装扮）：明黄雨衣——雨天识别度最高的配色。
  'rain' => const Color(0xFFF2C94C),
  // 雪装（天气装扮）：冰蓝，与冬季默认装的奶白区分开。
  'snow' => const Color(0xFFA8DADC),
  // 晴日装（天气装扮）：向日葵黄。
  'sunny' => const Color(0xFFF4A261),
  // 趋势装扮：注册表配色（未注册 = 没配色，底稿保持原样）。
  _ =>
      outfit.startsWith(trendOutfitPrefix) ? _trendColors[outfit]?.$1 : null,
};

/// 该装扮是否有可见配色（换装有感的前提；设置页预览与测试用）。
bool wardrobeKnows(String outfit) => outfitTintOf(outfit) != null;
