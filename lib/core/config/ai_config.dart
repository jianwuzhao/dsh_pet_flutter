/// 内置 AI 对话/碎碎念配置。
///
/// 上游 dsh-pet 的聊天与碎碎念由 DSH 宿主提供模型；Flutter 独立运行时没有宿主，
/// 所以这里用 OpenAI 兼容 / Ollama 两路可配，key 不进 jsonc（见 secret_store）。
library;

class AiConfig {
  const AiConfig({
    this.provider = 'none',
    this.baseUrl = 'https://api.openai.com/v1',
    this.model = 'gpt-4o-mini',
    this.whisperIntervalSec = 300,
    this.memoryRounds = 8,
    this.embeddingEnabled = false,
    this.embeddingModel = '',
  });

  /// none / openai / ollama。
  final String provider;

  /// OpenAI 兼容 baseUrl（含 /v1）或 Ollama 根地址。
  final String baseUrl;
  final String model;

  /// 自动碎碎念周期；<=0 表示不定时（仍可手动触发）。
  final int whisperIntervalSec;

  /// 每次对话带最近多少轮记忆。
  final int memoryRounds;

  /// 语义召回（P1-4）总开关：默认关，计划建议记忆总量 <200 条前不
  /// 启用——关键词召回够用，embedding 接口的延迟与成本不划算。
  final bool embeddingEnabled;

  /// embedding 模型；空 = 按 provider 取默认（openai:
  /// text-embedding-3-small / ollama: bge-m3）。
  final String embeddingModel;

  bool get enabled =>
      provider != 'none' &&
      provider.trim().isNotEmpty &&
      baseUrl.trim().isNotEmpty &&
      model.trim().isNotEmpty;

  bool get isOpenAi => provider == 'openai';
  bool get isOllama => provider == 'ollama';

  factory AiConfig.fromJson(Map<String, dynamic>? json, AiConfig fallback) {
    if (json == null) return fallback;
    String read(String key, String def) =>
        json[key] is String ? json[key] as String : def;
    int readInt(String key, int def) {
      final value = json[key];
      return value is num ? value.toInt() : def;
    }
    bool readBool(String key, bool def) =>
        json[key] is bool ? json[key] as bool : def;

    return AiConfig(
      provider: read('provider', fallback.provider).toLowerCase(),
      baseUrl: read('baseUrl', fallback.baseUrl),
      model: read('model', fallback.model),
      whisperIntervalSec: readInt(
        'whisperIntervalSec',
        fallback.whisperIntervalSec,
      ),
      memoryRounds: readInt('memoryRounds', fallback.memoryRounds),
      embeddingEnabled: readBool(
        'embeddingEnabled',
        fallback.embeddingEnabled,
      ),
      embeddingModel: read('embeddingModel', fallback.embeddingModel),
    );
  }

  AiConfig copyWith({
    String? provider,
    String? baseUrl,
    String? model,
    int? whisperIntervalSec,
    int? memoryRounds,
    bool? embeddingEnabled,
    String? embeddingModel,
  }) {
    return AiConfig(
      provider: provider ?? this.provider,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      whisperIntervalSec: whisperIntervalSec ?? this.whisperIntervalSec,
      memoryRounds: memoryRounds ?? this.memoryRounds,
      embeddingEnabled: embeddingEnabled ?? this.embeddingEnabled,
      embeddingModel: embeddingModel ?? this.embeddingModel,
    );
  }

  Map<String, dynamic> toJson() => {
    'provider': provider,
    'baseUrl': baseUrl,
    'model': model,
    'whisperIntervalSec': whisperIntervalSec,
    'memoryRounds': memoryRounds,
    'embeddingEnabled': embeddingEnabled,
    'embeddingModel': embeddingModel,
  };
}
