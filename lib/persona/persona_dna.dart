/// 人格 DNA：宠物的身份与表达底线。
///
/// 这些字段是**安全边界**：学习治理层只能读、不能改（EvalGate 的
/// protectedFields 硬编码引用），修改只能由用户在设置页手动完成。
/// “不操纵、不过度拟人、不制造依赖”是底线里的底线，默认即内置。
library;

class PersonaDna {
  const PersonaDna({
    this.name = '大肥鱼',
    this.address = '主人',
    this.toneCore = '温暖、简洁、诚实',
    this.bottomLines = defaultBottomLines,
    this.proactiveness = 0.4,
  });

  /// 内置底线：即使用户不配置也生效，会拼进 system prompt 的硬规则。
  static const List<String> defaultBottomLines = [
    '不操纵用户',
    '不过度拟人',
    '不制造依赖',
  ];

  /// 宠物自称的名字。
  final String name;

  /// 对用户的称呼（如“主人/老板”，可被记忆偏好覆盖）。
  final String address;

  /// 语气核心：所有表达（气泡/回复/主动关心）都要过这道口味检查。
  final String toneCore;

  /// 底线清单：拼进 system prompt，任何策略更新不得触碰。
  final List<String> bottomLines;

  /// 主动程度 0~1：喂给打扰预算做全局缩放（0 = 完全被动）。
  final double proactiveness;

  factory PersonaDna.fromJson(Map<String, dynamic> json) {
    double readDouble(String key, double fallback) {
      final value = json[key];
      if (value is num) return value.toDouble().clamp(0, 1);
      return fallback;
    }

    return PersonaDna(
      name: json['name'] is String && (json['name'] as String).isNotEmpty
          ? json['name'] as String
          : '大肥鱼',
      address: json['address'] is String ? json['address'] as String : '主人',
      toneCore: json['toneCore'] is String
          ? json['toneCore'] as String
          : '温暖、简洁、诚实',
      bottomLines: _readLines(json['bottomLines']),
      proactiveness: readDouble('proactiveness', 0.4),
    );
  }

  /// 底线清单不允许被解析成空：空 = 没有底线，违背设计前提。
  static List<String> _readLines(Object? raw) {
    if (raw is List) {
      final lines = [
        for (final item in raw)
          if (item is String && item.trim().isNotEmpty) item.trim(),
      ];
      if (lines.isNotEmpty) return lines;
    }
    return defaultBottomLines;
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'address': address,
    'toneCore': toneCore,
    'bottomLines': bottomLines,
    'proactiveness': proactiveness,
  };

  PersonaDna copyWith({
    String? name,
    String? address,
    String? toneCore,
    List<String>? bottomLines,
    double? proactiveness,
  }) => PersonaDna(
    name: name ?? this.name,
    address: address ?? this.address,
    toneCore: toneCore ?? this.toneCore,
    bottomLines: bottomLines ?? this.bottomLines,
    proactiveness: proactiveness ?? this.proactiveness,
  );
}
