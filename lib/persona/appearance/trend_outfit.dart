/// 热门趋势装扮提案（P2-3b）：LLM 只出「纯文字创意」，
/// 素材仍由本地 wardrobe 渲染——不下载外部图片（计划的安全边界）。
///
/// 治理状态只有两件事：本周是否已提案、拒绝冷却到几号；
/// 单独落 trend_outfit.json，不进形象版本历史（装饰轨道不占回滚额度）。
library;

import 'dart:convert';
import 'dart:io';

import '../../core/paths/app_paths.dart';
import '../../core/result.dart';
import 'appearance_state.dart';

/// 待确认的趋势装扮建议（内存态：生命周期到确认/忽略/重启为止）。
class TrendOutfitProposal {
  const TrendOutfitProposal({
    required this.outfit,
    required this.theme,
    required this.main,
    required this.trim,
    required this.reason,
    required this.proposedAt,
  });

  /// 装扮名：trend-<主题>（走受控前缀白名单，不引入自由字符串）。
  final String outfit;

  /// 主题短语（已截断去控制字符，UI 直接展示、也拼进装扮名）。
  final String theme;

  /// 围巾主/辅色（0xAARRGGBB，渲染层直接消费）。
  final int main;
  final int trim;

  /// 一句创意理由（已截断）。
  final String reason;
  final DateTime proposedAt;
}

/// 提案治理状态：周限、拒绝冷却与已穿装扮的配色回放。
/// 可整体丢弃——最坏情况是本周多提一次、已穿趋势装重启后画不出
/// （回放缺席，非崩溃），因此读失败按空状态继续。
class TrendGate {
  const TrendGate({
    this.lastProposedWeek,
    this.rejectedUntilMs,
    this.acceptedOutfit,
    this.acceptedMain,
    this.acceptedTrim,
  });

  /// 最近一次提案的周键；null = 从未提案。
  final String? lastProposedWeek;

  /// 拒绝冷却截止（epoch 毫秒）；null 或已过期 = 不在冷却。
  final int? rejectedUntilMs;

  /// 已穿上身的趋势装扮（trend- 前缀）与配色：配色注册表是内存态，
  /// 冻结形象时换装轨道不回落季节装，重启必须靠这份记录补注册，
  /// 否则会出现「穿着合法装扮却画不出图层」。
  final String? acceptedOutfit;
  final int? acceptedMain;
  final int? acceptedTrim;

  TrendGate copyWith({
    String? lastProposedWeek,
    int? rejectedUntilMs,
    String? acceptedOutfit,
    int? acceptedMain,
    int? acceptedTrim,
  }) => TrendGate(
    lastProposedWeek: lastProposedWeek ?? this.lastProposedWeek,
    rejectedUntilMs: rejectedUntilMs ?? this.rejectedUntilMs,
    acceptedOutfit: acceptedOutfit ?? this.acceptedOutfit,
    acceptedMain: acceptedMain ?? this.acceptedMain,
    acceptedTrim: acceptedTrim ?? this.acceptedTrim,
  );

  Map<String, dynamic> toJson() => {
    if (lastProposedWeek != null) 'week': lastProposedWeek,
    if (rejectedUntilMs != null) 'cooldownUntil': rejectedUntilMs,
    if (acceptedOutfit != null) ...{
      'acceptedOutfit': acceptedOutfit,
      'acceptedMain': acceptedMain,
      'acceptedTrim': acceptedTrim,
    },
  };

  static TrendGate fromJson(Map<String, dynamic> json) {
    final outfit = json['acceptedOutfit'] as String?;
    final main = (json['acceptedMain'] as num?)?.toInt();
    final trim = (json['acceptedTrim'] as num?)?.toInt();
    // 回放三元组要么完整要么整体丢弃：半个三元组画不出图层，
    // 脏数据按「没穿过」处理（重启回落季节装，安全侧）。
    final complete =
        outfit != null &&
        outfit.startsWith(trendOutfitPrefix) &&
        main != null &&
        trim != null;
    return TrendGate(
      lastProposedWeek: json['week'] as String?,
      rejectedUntilMs: (json['cooldownUntil'] as num?)?.toInt(),
      acceptedOutfit: complete ? outfit : null,
      acceptedMain: complete ? main : null,
      acceptedTrim: complete ? trim : null,
    );
  }
}

/// 周键（年 + 第几周）：粗粒度防打扰即可，跨年边界不追求 ISO 对齐。
String trendWeekKey(DateTime now) {
  final dayOfYear = now.difference(DateTime(now.year)).inDays;
  return '${now.year}-w${dayOfYear ~/ 7}';
}

/// 拒绝冷却时长：计划 D5 确认的默认值。
const trendRejectCooldown = Duration(days: 7);

class TrendOutfitStore {
  TrendOutfitStore({Directory? directory})
    : _directory = directory ?? AppPaths.profileDir;

  final Directory _directory;

  File get _file =>
      File('${_directory.path}${Platform.pathSeparator}trend_outfit.json');

  TrendGate load() {
    try {
      final file = _file;
      if (!file.existsSync()) return const TrendGate();
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map<String, dynamic>) return const TrendGate();
      return TrendGate.fromJson(raw);
    } on Object {
      // 治理状态是防打扰预算，不是审计数据：损坏按「从未提案」继续。
      return const TrendGate();
    }
  }

  Result<void> save(TrendGate gate) {
    try {
      if (!_directory.existsSync()) _directory.createSync(recursive: true);
      final tmp = File('${_file.path}.tmp');
      tmp.writeAsStringSync(jsonEncode(gate.toJson()), flush: true);
      tmp.renameSync(_file.path);
      return const Success(null);
    } on Object catch (error) {
      return Failure('trend.write-failed', '趋势提案状态写盘失败：$error');
    }
  }
}

/// 解析 LLM 输出为提案；任何字段不合法整体作废返回 null（安全侧）。
TrendOutfitProposal? parseTrendProposal(String raw, DateTime now) {
  // LLM 偶尔在 JSON 外包一层话术：截首尾大括号之间的部分再解。
  final start = raw.indexOf('{');
  final end = raw.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(raw.substring(start, end + 1));
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  final theme = _clip(decoded['theme']);
  final reason = _clip(decoded['reason'], 60);
  final main = _hexOf(decoded['main']);
  final trim = _hexOf(decoded['trim']);
  if (theme.isEmpty || reason.isEmpty || main == null || trim == null) {
    return null;
  }
  return TrendOutfitProposal(
    outfit: '$trendOutfitPrefix$theme',
    theme: theme,
    main: main,
    trim: trim,
    reason: reason,
    proposedAt: now,
  );
}

String _clip(Object? value, [int max = 12]) {
  if (value is! String) return '';
  // 去控制字符：主题会拼进装扮名，不能带不可见字符。
  final cleaned = value
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '')
      .trim();
  return cleaned.length <= max ? cleaned : cleaned.substring(0, max);
}

int? _hexOf(Object? value) {
  if (value is! String) return null;
  var hex = value.trim();
  if (hex.startsWith('#')) hex = hex.substring(1);
  if (hex.length != 6) return null;
  final rgb = int.tryParse(hex, radix: 16);
  return rgb == null ? null : 0xFF000000 | rgb;
}
