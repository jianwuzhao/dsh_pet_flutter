/// 情境换装决策：纯函数、无随机，日期信号 100% 本地计算。
///
/// 与人格驱动推演（AppearanceEvolution）是两条独立轨道：
/// - 优先级：节令 > 天气 > 季节；每次只决定 outfit 一个维度；
/// - 季节/节令换装全自动（装饰层低风险，冻结兜底可停）；
///   天气与热门装扮只产生提案，用户确认后才经 [AppearanceSignals.weather]
///   参与决策（P2-3 接线）；
/// - 时钟回拨等日期异常保持现状不切换，避免来回跳装。
library;

import 'appearance_evolution.dart';
import 'appearance_state.dart';

/// 四季（按节气近似日分界，不用气象学的整月划分）。
enum AppearanceSeason { spring, summer, autumn, winter }

/// 节气近似日期表（月/日）：误差 ±1~2 天，对装扮这种装饰维度无感。
///
/// 顺序即时间序；跨年时「小寒/大寒」排在最前。
const List<(String, int, int)> _solarTerms = [
  ('小寒', 1, 5),
  ('大寒', 1, 20),
  ('立春', 2, 4),
  ('雨水', 2, 19),
  ('惊蛰', 3, 5),
  ('春分', 3, 20),
  ('清明', 4, 5),
  ('谷雨', 4, 20),
  ('立夏', 5, 6),
  ('小满', 5, 21),
  ('芒种', 6, 6),
  ('夏至', 6, 21),
  ('小暑', 7, 7),
  ('大暑', 7, 23),
  ('立秋', 8, 7),
  ('处暑', 8, 23),
  ('白露', 9, 7),
  ('秋分', 9, 23),
  ('寒露', 10, 8),
  ('霜降', 10, 23),
  ('立冬', 11, 7),
  ('小雪', 11, 22),
  ('大雪', 12, 7),
  ('冬至', 12, 22),
];

/// 固定公历节令（月/日）。
const Map<String, (int, int)> _fixedFestivals = {
  'halloween': (10, 31),
  'christmas': (12, 25),
};

/// 农历节令查表（春节/中秋，2026-2035）。
///
/// 农历换算没有轻量算法：十年查表 + 每年 ±1 天误差，
/// 落在 ±3 天节令窗口内用户无感；超出表范围返回 null（不换装，安全侧）。
const Map<int, Map<String, (int, int)>> _lunarFestivals = {
  2026: {'newyear': (2, 17), 'midautumn': (9, 25)},
  2027: {'newyear': (2, 6), 'midautumn': (9, 15)},
  2028: {'newyear': (1, 26), 'midautumn': (10, 3)},
  2029: {'newyear': (2, 13), 'midautumn': (9, 22)},
  2030: {'newyear': (2, 3), 'midautumn': (9, 12)},
  2031: {'newyear': (1, 23), 'midautumn': (10, 1)},
  2032: {'newyear': (2, 11), 'midautumn': (9, 19)},
  2033: {'newyear': (1, 31), 'midautumn': (9, 8)},
  2034: {'newyear': (2, 19), 'midautumn': (9, 28)},
  2035: {'newyear': (2, 8), 'midautumn': (9, 17)},
};

/// 节令装扮的生效窗口：正日前后各 [festivalWindowDays] 天。
const int festivalWindowDays = 3;

/// 当前季节：立春 2/4、立夏 5/6、立秋 8/7、立冬 11/7 起算。
AppearanceSeason seasonOf(DateTime now) {
  final monthDay = now.month * 100 + now.day;
  if (monthDay >= 1107 || monthDay < 204) return AppearanceSeason.winter;
  if (monthDay < 506) return AppearanceSeason.spring;
  if (monthDay < 807) return AppearanceSeason.summer;
  return AppearanceSeason.autumn;
}

/// 当前节气名（近似日期表内最后一个已到的节气）。
String solarTermOf(DateTime now) {
  var term = _solarTerms.last.$1;
  for (final (name, month, day) in _solarTerms) {
    if (now.month * 100 + now.day >= month * 100 + day) term = name;
  }
  return term;
}

/// 当前处于窗口内的节令装扮；无节令返回 null。
String? festivalOf(DateTime now) {
  for (final entry in _fixedFestivals.entries) {
    if (_withinWindow(now, entry.value.$1, entry.value.$2)) return entry.key;
  }
  final lunar = _lunarFestivals[now.year];
  if (lunar == null) return null;
  for (final entry in lunar.entries) {
    if (_withinWindow(now, entry.value.$1, entry.value.$2)) return entry.key;
  }
  return null;
}

bool _withinWindow(DateTime now, int month, int day) {
  final target = DateTime(now.year, month, day);
  return (now.difference(target).inDays).abs() <= festivalWindowDays;
}

/// 换装决策结果：changed=false 时 outfit 沿用 current（调用方直接忽略）。
class OutfitDecision {
  const OutfitDecision({
    required this.outfit,
    required this.source,
    required this.changed,
    required this.reason,
  });

  final String outfit;
  final AppearanceOutfitSource source;
  final bool changed;
  final String reason;
}

/// 决策今天的装扮。只动 outfit/outfitSource 一维，其余维度原样保留。
///
/// signals 里的 festival/season 通常留空由本地日期计算兜底；
/// weather 只在用户确认过天气提案的当天由内核传入。
OutfitDecision decideOutfit(AppearanceState current, AppearanceSignals signals) {
  if (current.frozen) {
    return OutfitDecision(
      outfit: current.outfit,
      source: current.outfitSource,
      changed: false,
      reason: '形象已冻结，情境换装暂停',
    );
  }
  // 时钟回拨（now 早于上次形象变化）说明日期信号不可信，保持现状。
  if (signals.now.isBefore(current.updatedAt)) {
    return OutfitDecision(
      outfit: current.outfit,
      source: current.outfitSource,
      changed: false,
      reason: '日期信号异常（时钟回拨），保持现状',
    );
  }

  final festival = signals.festival ?? festivalOf(signals.now);
  final weather = signals.weather;
  final season = signals.season ?? seasonOf(signals.now);

  OutfitDecision keep() => OutfitDecision(
    outfit: current.outfit,
    source: current.outfitSource,
    changed: false,
    reason: '装扮无需变化',
  );

  // 优先级：节令 > 天气 > 季节；高优先级装扮生效中不被低优先级抢回。
  if (festival != null) {
    if (festival == current.outfit) return keep();
    return OutfitDecision(
      outfit: festival,
      source: AppearanceOutfitSource.festive,
      changed: true,
      reason: '临近${_festivalLabel(festival)}，换上节令装扮',
    );
  }
  final weatherActive = weather != null && isValidOutfitName(weather);
  if (weatherActive) {
    if (weather == current.outfit) return keep();
    return OutfitDecision(
      outfit: weather,
      source: AppearanceOutfitSource.weather,
      changed: true,
      reason: '按今日天气（${_festivalLabel(weather)}）换装',
    );
  }
  final seasonalOutfit = season.name;
  if (seasonalOutfit != current.outfit) {
    return OutfitDecision(
      outfit: seasonalOutfit,
      source: AppearanceOutfitSource.seasonal,
      changed: true,
      reason: '${_festivalLabel(seasonalOutfit)}到了，换上应季装扮',
    );
  }
  return keep();
}

/// 装扮名转展示文案；未知名原样返回（trend-* 提案自带主题名）。
String _festivalLabel(String outfit) => switch (outfit) {
  'newyear' => '春节',
  'midautumn' => '中秋',
  'halloween' => '万圣夜',
  'christmas' => '圣诞节',
  'rain' => '雨',
  'snow' => '雪',
  'sunny' => '晴',
  'spring' => '春天',
  'summer' => '夏天',
  'autumn' => '秋天',
  'winter' => '冬天',
  _ => outfit,
};
