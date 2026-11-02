/// 形象状态模型：把「长什么样」拆成可枚举、可比较、可回滚的六维。
///
/// 设计约束（防止形象越跑越偏）：
/// - 每个维度都是**有序枚举**或**有硬边界**的数值，演化只能相邻移动；
/// - 不引入随机数，同等输入必得同等输出（可复现、可测试）；
/// - 每次推演最多改一个维度，改动幅度与频率由 evolve 层限制。
library;

/// 体型形态（有序：越靠后越敦实）。
enum AppearanceForm { slim, round, chubby, tall }

/// 主配色（语义化色板名，渲染层负责实际色值）。
enum AppearancePalette { blue, green, orange, purple, gray }

/// 配饰（按亲密度递进：无 → 围巾 → 眼镜 → 帽子）。
enum AppearanceAccessory { none, scarf, glasses, hat }

/// 动作组：决定待机/移动时优先点播哪一类动画。
enum AppearanceMotionSet { lively, playful, calm, sleepy }

/// 表情集：决定气泡配图与表情帧的倾向。
enum AppearanceExpressionSet { soft, bright, cool, shy }

/// 体型缩放的硬边界：超出范围一律夹取，避免视觉失真。
const double appearanceMinBodyScale = 0.85;
const double appearanceMaxBodyScale = 1.15;

class AppearanceState {
  const AppearanceState({
    this.revision = 0,
    this.form = AppearanceForm.round,
    this.bodyScale = 1.0,
    this.palette = AppearancePalette.blue,
    this.accessory = AppearanceAccessory.none,
    this.motionSet = AppearanceMotionSet.calm,
    this.expressionSet = AppearanceExpressionSet.soft,
    this.frozen = false,
    this.updatedAtMs = 0,
  });

  /// 修订号：每次真正变化 +1，回滚时也 +1（回滚本身也留痕）。
  final int revision;
  final AppearanceForm form;

  /// 体型缩放：只允许在 [appearanceMinBodyScale, appearanceMaxBodyScale] 内。
  final double bodyScale;
  final AppearancePalette palette;
  final AppearanceAccessory accessory;
  final AppearanceMotionSet motionSet;
  final AppearanceExpressionSet expressionSet;

  /// 冻结后不再接受任何自动演化（用户手动改不受限）。
  final bool frozen;

  /// 上次变化时间（毫秒时间戳；0 = 从未演化过）。
  ///
  /// 存整数而非 DateTime：const 构造器不接受非常量默认值。
  final int updatedAtMs;

  DateTime get updatedAt => DateTime.fromMillisecondsSinceEpoch(updatedAtMs);

  AppearanceState copyWith({
    int? revision,
    AppearanceForm? form,
    double? bodyScale,
    AppearancePalette? palette,
    AppearanceAccessory? accessory,
    AppearanceMotionSet? motionSet,
    AppearanceExpressionSet? expressionSet,
    bool? frozen,
    int? updatedAtMs,
  }) => AppearanceState(
    revision: revision ?? this.revision,
    form: form ?? this.form,
    bodyScale: clampBodyScale(bodyScale ?? this.bodyScale),
    palette: palette ?? this.palette,
    accessory: accessory ?? this.accessory,
    motionSet: motionSet ?? this.motionSet,
    expressionSet: expressionSet ?? this.expressionSet,
    frozen: frozen ?? this.frozen,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
  );

  static double clampBodyScale(double value) =>
      value.clamp(appearanceMinBodyScale, appearanceMaxBodyScale);

  /// 稳定的比较键：用于判断「这次推演到底有没有变化」。
  String get signature =>
      '${form.name}|${bodyScale.toStringAsFixed(3)}|${palette.name}|'
      '${accessory.name}|${motionSet.name}|${expressionSet.name}|$frozen';

  Map<String, dynamic> toJson() => {
    'revision': revision,
    'form': form.name,
    'bodyScale': bodyScale,
    'palette': palette.name,
    'accessory': accessory.name,
    'motionSet': motionSet.name,
    'expressionSet': expressionSet.name,
    'frozen': frozen,
    // 写 ISO 字符串便于人工排查；读取同时兼容毫秒整数。
    'updatedAt': updatedAt.toIso8601String(),
  };

  /// 解析：未知枚举值回落到默认项（向前兼容新版本写入的字段）。
  factory AppearanceState.fromJson(Map<String, dynamic> json) => AppearanceState(
    revision: (json['revision'] as num?)?.toInt() ?? 0,
    form: _enumOf(AppearanceForm.values, json['form']) ?? AppearanceForm.round,
    bodyScale: clampBodyScale((json['bodyScale'] as num?)?.toDouble() ?? 1.0),
    palette:
        _enumOf(AppearancePalette.values, json['palette']) ??
        AppearancePalette.blue,
    accessory:
        _enumOf(AppearanceAccessory.values, json['accessory']) ??
        AppearanceAccessory.none,
    motionSet:
        _enumOf(AppearanceMotionSet.values, json['motionSet']) ??
        AppearanceMotionSet.calm,
    expressionSet:
        _enumOf(AppearanceExpressionSet.values, json['expressionSet']) ??
        AppearanceExpressionSet.soft,
    frozen: json['frozen'] as bool? ?? false,
    updatedAtMs: _timestampOf(json['updatedAt']),
  );

  static int _timestampOf(Object? raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) {
      return DateTime.tryParse(raw)?.millisecondsSinceEpoch ?? 0;
    }
    return 0;
  }

  static T? _enumOf<T extends Enum>(List<T> values, Object? raw) {
    if (raw is! String) return null;
    for (final value in values) {
      if (value.name == raw) return value;
    }
    return null;
  }
}
