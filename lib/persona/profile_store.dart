/// 本地档案仓库：个性化层四份 JSON 的唯一读写口。
///
/// 语义约定（与 config 一致的“大声报错”原则）：
/// - 文件不存在 → 返回默认值（首次启动的自然路径）；
/// - 文件存在但损坏/结构不对 → 返回 Failure 并带上路径，**绝不静默回退**，
///   否则用户辛苦攒的画像会被一份“猜出来的默认值”悄悄覆盖掉。
/// - 写入全部原子化（tmp + rename），中途崩溃不留半截文件。
library;

import 'dart:convert';
import 'dart:io';

import '../core/paths/app_paths.dart';
import '../core/result.dart';
import 'persona_dna.dart';

/// 用户画像：作息、工作节奏、偏好、禁忌、常用工具。
/// 首期由用户手填 + 记忆提案确认后回填，不做自动推断。
class UserProfile {
  const UserProfile({
    this.routine = '',
    this.workRhythm = '',
    this.preferences = const [],
    this.taboos = const [],
    this.frequentApps = const [],
  });

  final String routine;
  final String workRhythm;
  final List<String> preferences;
  final List<String> taboos;
  final List<String> frequentApps;

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
    routine: json['routine'] is String ? json['routine'] as String : '',
    workRhythm: json['workRhythm'] is String
        ? json['workRhythm'] as String
        : '',
    preferences: _lines(json['preferences']),
    taboos: _lines(json['taboos']),
    frequentApps: _lines(json['frequentApps']),
  );

  Map<String, dynamic> toJson() => {
    'routine': routine,
    'workRhythm': workRhythm,
    'preferences': preferences,
    'taboos': taboos,
    'frequentApps': frequentApps,
  };
}

/// 情绪档案 + 主动打扰预算：除话术池外还承载预算字段的持久化
/// （打扰计数按日落盘，日期翻转清零由预算模块负责）。
class EmotionProfile {
  const EmotionProfile({
    this.emotionEnabled = true,
    this.comfortPhrases = defaultComfortPhrases,
    this.avoidedTopics = const [],
    this.quietStart = '22:00',
    this.quietEnd = '08:00',
    this.careEnabled = true,
    this.dailyCareLimit = 3,
    this.focusMode = false,
    this.intimacyBaseline = 0.3,
    this.persistedIntimacy = -1,
    this.persistedAtMs = 0,
    this.careDate = '',
    this.careCount = 0,
    this.lastCareAtMs = 0,
    this.lastCareState = '',
  });

  static const List<String> defaultComfortPhrases = [
    '辛苦了，要不要先休息一下？',
    '我在呢，慢慢来。',
  ];

  /// 情绪引擎总开关：关闭=纯联动桌宠，不感知不表达（设置页可切）。
  final bool emotionEnabled;

  final List<String> comfortPhrases;
  final List<String> avoidedTopics;

  /// 安静时段（HH:mm，支持跨零点，如 22:00–08:00）。
  final String quietStart;
  final String quietEnd;

  /// 一键关闭主动关心（托盘/设置页/右键菜单都指到这里）。
  final bool careEnabled;
  final int dailyCareLimit;
  final bool focusMode;

  /// 亲密度基线：情绪三维里 intimacy 的慢回归目标。
  final double intimacyBaseline;

  /// 最近一次落盘的亲密度快照 ∈ [0,1]；-1 = 从未持久化（首次启动）。
  ///
  /// 没有它，每次重启 intimacy 都被拉回基线——用户攒了几天的
  /// 亲近感一夜清零，亲密度永远动不起来。
  final double persistedIntimacy;

  /// 快照时间（毫秒；0 = 从未持久化）。
  final int persistedAtMs;

  // ---- 以下为预算计数状态（非用户偏好，勿在设置页展示） ----
  final String careDate;
  final int careCount;
  final int lastCareAtMs;

  /// 上次主动关心时的情绪态名：同状态 1 小时限流用。
  final String lastCareState;

  factory EmotionProfile.fromJson(Map<String, dynamic> json) {
    int readInt(String key, int fallback) {
      final value = json[key];
      return value is num ? value.toInt() : fallback;
    }

    double readDouble(String key, double fallback) {
      final value = json[key];
      return value is num ? value.toDouble() : fallback;
    }

    return EmotionProfile(
      emotionEnabled: json['emotionEnabled'] is bool
          ? json['emotionEnabled'] as bool
          : true,
      comfortPhrases: _lines(json['comfortPhrases']),
      avoidedTopics: _lines(json['avoidedTopics']),
      quietStart: json['quietStart'] is String
          ? json['quietStart'] as String
          : '22:00',
      quietEnd: json['quietEnd'] is String
          ? json['quietEnd'] as String
          : '08:00',
      careEnabled: json['careEnabled'] is bool
          ? json['careEnabled'] as bool
          : true,
      dailyCareLimit: readInt('dailyCareLimit', 3),
      focusMode: json['focusMode'] is bool ? json['focusMode'] as bool : false,
      intimacyBaseline: readDouble('intimacyBaseline', 0.3).clamp(0, 1),
      // -1 保留“从未持久化”语义；有效值夹取 [0,1]。
      persistedIntimacy: readDouble('persistedIntimacy', -1) < 0
          ? -1
          : readDouble('persistedIntimacy', -1).clamp(0, 1),
      persistedAtMs: readInt('persistedAtMs', 0),
      careDate: json['careDate'] is String ? json['careDate'] as String : '',
      careCount: readInt('careCount', 0),
      lastCareAtMs: readInt('lastCareAtMs', 0),
      lastCareState: json['lastCareState'] is String
          ? json['lastCareState'] as String
          : '',
    );
  }

  Map<String, dynamic> toJson() => {
    'emotionEnabled': emotionEnabled,
    'comfortPhrases': comfortPhrases,
    'avoidedTopics': avoidedTopics,
    'quietStart': quietStart,
    'quietEnd': quietEnd,
    'careEnabled': careEnabled,
    'dailyCareLimit': dailyCareLimit,
    'focusMode': focusMode,
    'intimacyBaseline': intimacyBaseline,
    'persistedIntimacy': persistedIntimacy,
    'persistedAtMs': persistedAtMs,
    'careDate': careDate,
    'careCount': careCount,
    'lastCareAtMs': lastCareAtMs,
    'lastCareState': lastCareState,
  };

  EmotionProfile copyWith({
    bool? emotionEnabled,
    List<String>? comfortPhrases,
    List<String>? avoidedTopics,
    String? quietStart,
    String? quietEnd,
    bool? careEnabled,
    int? dailyCareLimit,
    bool? focusMode,
    double? intimacyBaseline,
    double? persistedIntimacy,
    int? persistedAtMs,
    String? careDate,
    int? careCount,
    int? lastCareAtMs,
    String? lastCareState,
  }) => EmotionProfile(
    emotionEnabled: emotionEnabled ?? this.emotionEnabled,
    comfortPhrases: comfortPhrases ?? this.comfortPhrases,
    avoidedTopics: avoidedTopics ?? this.avoidedTopics,
    quietStart: quietStart ?? this.quietStart,
    quietEnd: quietEnd ?? this.quietEnd,
    careEnabled: careEnabled ?? this.careEnabled,
    dailyCareLimit: dailyCareLimit ?? this.dailyCareLimit,
    focusMode: focusMode ?? this.focusMode,
    intimacyBaseline: intimacyBaseline ?? this.intimacyBaseline,
    persistedIntimacy: persistedIntimacy ?? this.persistedIntimacy,
    persistedAtMs: persistedAtMs ?? this.persistedAtMs,
    careDate: careDate ?? this.careDate,
    careCount: careCount ?? this.careCount,
    lastCareAtMs: lastCareAtMs ?? this.lastCareAtMs,
    lastCareState: lastCareState ?? this.lastCareState,
  );
}

/// 隐私授权：四项能力的单一事实来源，默认“少看多问”。
class PrivacySettings {
  const PrivacySettings({
    this.screenAwareness = false,
    this.appWatch = true,
    this.memoryRecording = true,
    this.proactiveCare = true,
  });

  /// 读前台窗口正文（迁移自 config.linkage.contentRead，默认关）。
  final bool screenAwareness;

  /// 感知前台应用切换（只看应用名，不读内容）。
  final bool appWatch;

  /// 记录长期记忆（关闭后记忆库只读不写）。
  final bool memoryRecording;

  /// 主动关心（还要再过打扰预算）。
  final bool proactiveCare;

  factory PrivacySettings.fromJson(Map<String, dynamic> json) =>
      PrivacySettings(
        screenAwareness: json['screenAwareness'] is bool
            ? json['screenAwareness'] as bool
            : false,
        appWatch: json['appWatch'] is bool ? json['appWatch'] as bool : true,
        memoryRecording: json['memoryRecording'] is bool
            ? json['memoryRecording'] as bool
            : true,
        proactiveCare: json['proactiveCare'] is bool
            ? json['proactiveCare'] as bool
            : true,
      );

  Map<String, dynamic> toJson() => {
    'screenAwareness': screenAwareness,
    'appWatch': appWatch,
    'memoryRecording': memoryRecording,
    'proactiveCare': proactiveCare,
  };

  PrivacySettings copyWith({
    bool? screenAwareness,
    bool? appWatch,
    bool? memoryRecording,
    bool? proactiveCare,
  }) => PrivacySettings(
    screenAwareness: screenAwareness ?? this.screenAwareness,
    appWatch: appWatch ?? this.appWatch,
    memoryRecording: memoryRecording ?? this.memoryRecording,
    proactiveCare: proactiveCare ?? this.proactiveCare,
  );
}

List<String> _lines(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final item in raw)
      if (item is String && item.trim().isNotEmpty) item.trim(),
  ];
}

class ProfileStore {
  ProfileStore({Directory? directory})
    : _dir = directory ?? AppPaths.profileDir;

  final Directory _dir;

  File _file(String name) => File('${_dir.path}${Platform.pathSeparator}$name');

  Result<PersonaDna> loadPersonaDna() =>
      _load('persona_dna.json', PersonaDna.fromJson);

  Result<UserProfile> loadUserProfile() =>
      _load('user_profile.json', UserProfile.fromJson);

  Result<EmotionProfile> loadEmotionProfile() =>
      _load('emotion_profile.json', EmotionProfile.fromJson);

  Result<PrivacySettings> loadPrivacy() =>
      _load('privacy.json', PrivacySettings.fromJson);

  /// privacy.json 是否已存在：权限中心用它判断“首次启动迁移”还是“读取”。
  bool get hasPrivacy => _file('privacy.json').existsSync();

  Result<void> savePersonaDna(PersonaDna value) =>
      _save('persona_dna.json', value.toJson());

  Result<void> saveUserProfile(UserProfile value) =>
      _save('user_profile.json', value.toJson());

  Result<void> saveEmotionProfile(EmotionProfile value) =>
      _save('emotion_profile.json', value.toJson());

  Result<void> savePrivacy(PrivacySettings value) =>
      _save('privacy.json', value.toJson());

  Result<T> _load<T>(String name, T Function(Map<String, dynamic>) parse) {
    final file = _file(name);
    if (!file.existsSync()) {
      // 不存在 = 首次启动，给默认值；字段级缺省由各模型 fromJson 兜。
      return Success(parse(const {}));
    }
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('顶层不是 JSON 对象');
      }
      return Success(parse(decoded));
    } on Object catch (error) {
      return Failure(
        'profile.parse',
        '档案损坏，拒绝静默覆盖：${file.path}（$error）。'
        '请手工修复或删除该文件后重启。',
      );
    }
  }

  Result<void> _save(String name, Map<String, dynamic> value) {
    final file = _file(name);
    try {
      if (!_dir.existsSync()) _dir.createSync(recursive: true);
      final tmp = File('${file.path}.tmp');
      tmp.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(value),
        flush: true,
      );
      tmp.renameSync(file.path);
      return const Success(null);
    } on Object catch (error) {
      return Failure('profile.save', '保存档案失败：${file.path}（$error）');
    }
  }
}
