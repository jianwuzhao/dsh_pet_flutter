/// 衣橱：登记哪些形象变体有成套素材包（assets/appearance/<变体>/）。
///
/// 形象演化不做任何程序化改色或叠加——变体要有真素材（按提示词用 AI
/// 重新生成的整套动画）才可见。衣橱只回答两件事：某变体有没有包、包里
/// 有哪些动作；包缺失或动作缺失都回退默认动画包（assets/animations/），
/// 也就是原版立绘——宁可暂时「没换装」，不用滤镜假装换装。
library;

import '../../../persona/appearance/appearance_state.dart';

/// 变体素材包登记表：变体名 → 包内动作名集合。
class Wardrobe {
  const Wardrobe(this._packs);

  /// 空衣橱：所有形象都回退默认动画包（无任何素材包时的初始态）。
  const Wardrobe.empty() : _packs = const {};

  final Map<String, Set<String>> _packs;

  /// 变体有成套素材包。
  bool knows(String variant) => _packs.containsKey(variant);

  /// 变体包里有没有这个动作（单条动画能否用该包素材）。
  bool has(String? variant, String animation) =>
      variant != null && (_packs[variant]?.contains(animation) ?? false);

  /// 当前形象该穿哪套素材：装扮（情境级）优先于配色（人格级）；
  /// blue 即素材原色、不需要包。都没有则 null = 默认动画包。
  String? packVariantOf(AppearanceState appearance) {
    if (knows(appearance.outfit)) return appearance.outfit;
    final palette = appearance.palette.name;
    if (palette != 'blue' && knows(palette)) return palette;
    return null;
  }

  /// 解析 assets/appearance/registry.json：
  /// {"packs": {"rain": {"names": ["待机呼吸休闲", ...]}}}
  /// 结构不符合预期按空衣橱处理（安全侧：全部回退默认包）。
  factory Wardrobe.fromJson(Map<String, dynamic> json) {
    final packs = json['packs'];
    if (packs is! Map<String, dynamic>) return const Wardrobe.empty();
    final parsed = <String, Set<String>>{};
    for (final entry in packs.entries) {
      final spec = entry.value;
      if (spec is! Map<String, dynamic>) continue;
      final names = spec['names'];
      if (names is! List) continue;
      final set = {
        for (final name in names)
          if (name is String) name,
      };
      // 空名单的包登记了也画不出任何东西，直接不收。
      if (set.isNotEmpty) parsed[entry.key] = set;
    }
    return Wardrobe(parsed);
  }
}
