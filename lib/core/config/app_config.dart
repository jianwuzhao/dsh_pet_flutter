/// 配置模型与加载：内置默认（assets）→ 用户覆盖（~/.dsh_pet_flutter/config.jsonc）。
///
/// 合并口径沿用上游：**整段替换**——用户写了 `pets` 就整段用自己的，缺的子键不回头补默认；
/// 解析失败**大声报错**（返回 Failure），绝不静默用一份“猜出来的”配置继续跑。
library;

import 'dart:convert';

import 'package:flutter/services.dart';

import '../paths/app_paths.dart';
import 'jsonc.dart';
import '../result.dart';
import '../../features/pet/behavior/physics.dart';
import 'ai_config.dart';

class PetConfig {
  const PetConfig({
    required this.id,
    required this.name,
    required this.size,
    required this.display,
    required this.whisperEnabled,
    required this.workStatusEnabled,
    this.whisperPrompt = '',
  });

  final String id;
  final String name;

  /// 宠物显示宽度（逻辑像素）。
  final double size;

  /// web / desktop / both / none，与上游同义。
  final String display;
  final bool whisperEnabled;
  final bool workStatusEnabled;
  final String whisperPrompt;

  bool get showsOnDesktop => display == 'desktop' || display == 'both';

  factory PetConfig.fromJson(Map<String, dynamic> json, PetConfig fallback) {
    String readString(String key, String def) {
      final value = json[key];
      return value is String ? value : def;
    }

    double readSize() {
      final value = json['size'];
      if (value is num && value > 0) return value.toDouble();
      return fallback.size;
    }

    return PetConfig(
      id: readString('id', fallback.id),
      name: readString('name', fallback.name),
      size: readSize(),
      display: readString('display', fallback.display),
      whisperEnabled: json['whisperEnabled'] is bool
          ? json['whisperEnabled'] as bool
          : fallback.whisperEnabled,
      workStatusEnabled: json['workStatusEnabled'] is bool
          ? json['workStatusEnabled'] as bool
          : fallback.workStatusEnabled,
      whisperPrompt: readString('whisperPrompt', fallback.whisperPrompt),
    );
  }
}

enum DeliveryMode { uri, clipboard, http, ws }

DeliveryMode _deliveryFrom(String? raw, DeliveryMode fallback) {
  switch (raw) {
    case 'uri':
      return DeliveryMode.uri;
    case 'clipboard':
      return DeliveryMode.clipboard;
    case 'http':
      return DeliveryMode.http;
    case 'ws':
      return DeliveryMode.ws;
    default:
      return fallback;
  }
}

class AdapterConfig {
  const AdapterConfig({
    required this.id,
    required this.displayName,
    required this.appName,
    required this.bundleId,
    required this.uriTemplate,
    required this.delivery,
    this.endpoint = '',
    this.token = '',
  });

  final String id;
  final String displayName;

  /// 前台应用识别用的显示名正则（大小写不敏感）。
  final String appName;
  final String bundleId;

  /// 唤起模板，`{prompt}` 会被替换为 URL 编码后的输入。
  final String uriTemplate;
  final DeliveryMode delivery;
  final String endpoint;
  final String token;

  factory AdapterConfig.fromJson(
    String id,
    Map<String, dynamic> json,
    AdapterConfig fallback,
  ) {
    String read(String key, String def) =>
        json[key] is String ? json[key] as String : def;
    return AdapterConfig(
      id: id,
      displayName: read('displayName', fallback.displayName),
      appName: read('appName', fallback.appName),
      bundleId: read('bundleId', fallback.bundleId),
      uriTemplate: read('uriTemplate', fallback.uriTemplate),
      delivery: _deliveryFrom(json['delivery'] as String?, fallback.delivery),
      endpoint: read('endpoint', fallback.endpoint),
      token: read('token', fallback.token),
    );
  }

  AdapterConfig copyWith({
    String? displayName,
    String? appName,
    String? bundleId,
    String? uriTemplate,
    DeliveryMode? delivery,
    String? endpoint,
    String? token,
  }) {
    return AdapterConfig(
      id: id,
      displayName: displayName ?? this.displayName,
      appName: appName ?? this.appName,
      bundleId: bundleId ?? this.bundleId,
      uriTemplate: uriTemplate ?? this.uriTemplate,
      delivery: delivery ?? this.delivery,
      endpoint: endpoint ?? this.endpoint,
      token: token ?? this.token,
    );
  }
}

class LinkageConfig {
  const LinkageConfig({
    required this.active,
    required this.adapters,
    required this.port,
    required this.contentRead,
  });

  final String active;
  final Map<String, AdapterConfig> adapters;
  final int port;

  /// 是否允许读前台窗口正文（需要系统辅助功能授权）。
  final bool contentRead;

  AdapterConfig? get activeAdapter => adapters[active];
}

class AppConfig {
  const AppConfig({
    required this.pets,
    required this.physics,
    required this.linkage,
    this.ai = const AiConfig(),
  });

  final List<PetConfig> pets;
  final PhysicsParams physics;
  final LinkageConfig linkage;
  final AiConfig ai;

  /// 首只“在桌面显示”的宠物；没有则不显示（与上游 display 语义一致）。
  PetConfig? get desktopPet => pets.where((p) => p.showsOnDesktop).firstOrNull;

  factory AppConfig.fromJson(Map<String, dynamic> json, AppConfig fallback) {
    final pets = <PetConfig>[];
    final rawPets = json['pets'];
    if (rawPets is List) {
      for (var i = 0; i < rawPets.length; i++) {
        final raw = rawPets[i];
        if (raw is! Map<String, dynamic>) continue;
        final base = i < fallback.pets.length
            ? fallback.pets[i]
            : fallback.pets.first;
        pets.add(PetConfig.fromJson(raw, base));
      }
    }

    final physics = PhysicsParams.fromJson(
      json['physics'] as Map<String, dynamic>?,
      fallback.physics,
    );

    final linkageRaw = json['linkage'] as Map<String, dynamic>?;
    var linkage = fallback.linkage;
    if (linkageRaw != null) {
      final adapters = Map<String, AdapterConfig>.from(
        fallback.linkage.adapters,
      );
      final adapterRaw = linkageRaw['adapters'];
      if (adapterRaw is Map) {
        for (final entry in adapterRaw.entries) {
          final id = entry.key as String;
          if (entry.value is! Map<String, dynamic>) continue;
          final base =
              adapters[id] ??
              AdapterConfig(
                id: id,
                displayName: id,
                appName: id,
                bundleId: '',
                uriTemplate: '',
                delivery: DeliveryMode.clipboard,
              );
          adapters[id] = AdapterConfig.fromJson(
            id,
            entry.value as Map<String, dynamic>,
            base,
          );
        }
      }

      final serverRaw = linkageRaw['eventServer'] as Map<String, dynamic>?;
      linkage = LinkageConfig(
        active: linkageRaw['active'] is String
            ? linkageRaw['active'] as String
            : linkage.active,
        adapters: adapters,
        port: (serverRaw?['port'] as num?)?.toInt() ?? linkage.port,
        contentRead: linkageRaw['contentRead'] is bool
            ? linkageRaw['contentRead'] as bool
            : linkage.contentRead,
      );
    }

    return AppConfig(
      pets: pets.isEmpty ? fallback.pets : pets,
      physics: physics,
      linkage: linkage,
      ai: AiConfig.fromJson(json['ai'] as Map<String, dynamic>?, fallback.ai),
    );
  }
}

class ConfigRepository {
  ConfigRepository({AssetBundle? bundle}) : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;

  static const String defaultAsset = 'assets/config.default.jsonc';

  Future<Result<AppConfig>> load() async {
    try {
      final defaults = _parse(await _bundle.loadString(defaultAsset), null);
      if (defaults is Failure<AppConfig>) return defaults;
      final base = (defaults as Success<AppConfig>).value;

      final userFile = AppPaths.configFile;
      if (!userFile.existsSync()) return Success(base);

      final user = _parse(await userFile.readAsString(), base);
      return user;
    } on Object catch (error) {
      return Failure('config.load', '读取配置失败：$error');
    }
  }

  Result<AppConfig> _parse(String source, AppConfig? fallback) {
    if (fallback == null) {
      // 默认配置必须能独立解析：它自带全部字段，不需要回落。
      try {
        final json = decodeJsonc(source) as Map<String, dynamic>;
        return Success(_buildDefault(json));
      } on Object catch (error) {
        return Failure('config.parse', '内置默认配置解析失败：$error');
      }
    }
    try {
      final json = decodeJsonc(source) as Map<String, dynamic>;
      return Success(AppConfig.fromJson(json, fallback));
    } on Object catch (error) {
      return Failure(
        'config.parse',
        '配置文件解析失败（${AppPaths.configFile.path}）：$error',
      );
    }
  }

  AppConfig _buildDefault(Map<String, dynamic> json) {
    final bootstrapPet = PetConfig(
      id: 'main',
      name: '蓝毛小女仆',
      size: 220,
      display: 'desktop',
      whisperEnabled: true,
      workStatusEnabled: true,
    );
    final bootstrapAdapter = AdapterConfig(
      id: 'generic',
      displayName: '通用',
      appName: '',
      bundleId: '',
      uriTemplate: '',
      delivery: DeliveryMode.clipboard,
    );
    final bootstrap = AppConfig(
      pets: [bootstrapPet],
      physics: const PhysicsParams(),
      linkage: LinkageConfig(
        active: bootstrapAdapter.id,
        adapters: {bootstrapAdapter.id: bootstrapAdapter},
        port: 7341,
        contentRead: false,
      ),
      ai: const AiConfig(),
    );
    return AppConfig.fromJson(json, bootstrap);
  }

  /// 把当前配置写回用户层（设置页保存时调用）。
  Future<Result<void>> save(AppConfig config) async {
    try {
      AppPaths.ensure();
      AppPaths.configFile.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(_toJson(config)),
        flush: true,
      );
      return const Success(null);
    } on Object catch (error) {
      return Failure('config.save', '保存配置失败：$error');
    }
  }

  Map<String, dynamic> _toJson(AppConfig config) => {
    'pets': [
      for (final pet in config.pets)
        {
          'id': pet.id,
          'name': pet.name,
          'size': pet.size,
          'display': pet.display,
          'whisperEnabled': pet.whisperEnabled,
          'workStatusEnabled': pet.workStatusEnabled,
          if (pet.whisperPrompt.isNotEmpty) 'whisperPrompt': pet.whisperPrompt,
        },
    ],
    // AI 段也要写回：用户文件整段覆盖，漏写会把配置好的 provider/model 清掉。
    'ai': config.ai.toJson(),
    // 物理参数也要写回：用户文件是“整段替换”，漏写会让自定义手感丢失。
    'physics': {
      'gravity': config.physics.gravity,
      'restitution': config.physics.restitution,
      'groundFriction': config.physics.groundFriction,
      'ceilingBounce': config.physics.ceilingBounce,
      'throwPower': config.physics.throwPower,
      'throwThreshold': config.physics.throwThreshold,
      'petCollision': config.physics.petCollision,
    },
    'linkage': {
      'active': config.linkage.active,
      'contentRead': config.linkage.contentRead,
      'eventServer': {'port': config.linkage.port},
      'adapters': {
        for (final entry in config.linkage.adapters.entries)
          entry.key: {
            'displayName': entry.value.displayName,
            'appName': entry.value.appName,
            'bundleId': entry.value.bundleId,
            'uriTemplate': entry.value.uriTemplate,
            'delivery': entry.value.delivery.name,
            'endpoint': entry.value.endpoint,
            'token': entry.value.token,
          },
      },
    },
  };
}
