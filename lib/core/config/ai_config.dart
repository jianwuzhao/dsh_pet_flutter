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

    return AiConfig(
      provider: read('provider', fallback.provider).toLowerCase(),
      baseUrl: read('baseUrl', fallback.baseUrl),
      model: read('model', fallback.model),
      whisperIntervalSec: readInt(
        'whisperIntervalSec',
        fallback.whisperIntervalSec,
      ),
      memoryRounds: readInt('memoryRounds', fallback.memoryRounds),
    );
  }

  AiConfig copyWith({
    String? provider,
    String? baseUrl,
    String? model,
    int? whisperIntervalSec,
    int? memoryRounds,
  }) {
    return AiConfig(
      provider: provider ?? this.provider,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      whisperIntervalSec: whisperIntervalSec ?? this.whisperIntervalSec,
      memoryRounds: memoryRounds ?? this.memoryRounds,
    );
  }

  Map<String, dynamic> toJson() => {
    'provider': provider,
    'baseUrl': baseUrl,
    'model': model,
    'whisperIntervalSec': whisperIntervalSec,
    'memoryRounds': memoryRounds,
  };
}
