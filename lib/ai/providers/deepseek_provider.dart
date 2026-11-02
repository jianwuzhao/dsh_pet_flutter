/// DeepSeek 提供者：官方 OpenAI 兼容端点（`https://api.deepseek.com/chat/completions`）。
///
/// 依据官方思考模式文档，深度思考用两个参数表达：
/// - `reasoning_effort`: low / high / max；
/// - `thinking.type`: enabled / disabled（直接发 HTTP body 时就是顶层字段，
///   等价于 OpenAI SDK 里的 `extra_body`）。
/// 思考模式下 temperature 等采样参数不生效，所以不在请求里下发。
library;

import '../thinking_tier.dart';
import 'openai_provider.dart';

class DeepSeekProvider extends OpenAiProvider {
  DeepSeekProvider({
    required super.baseUrl,
    required super.model,
    required super.keyLoader,
    super.client,
  });

  @override
  String get id => 'deepseek';

  @override
  String get displayName => 'DeepSeek';

  /// 三档思考深度映射到 DeepSeek 的 effort 与开关（见 thinking_tier.dart）。
  @override
  Map<String, dynamic> requestExtras(ThinkingTier tier) {
    final plan = deepseekThinkingFor(tier);
    return {
      'reasoning_effort': plan.effort,
      'thinking': {'type': plan.thinkingEnabled ? 'enabled' : 'disabled'},
    };
  }
}

/// 使用 DeepSeek 时推荐的默认端点与模型（设置页提示用）。
const String deepSeekDefaultBaseUrl = 'https://api.deepseek.com';
const String deepSeekDefaultModel = 'deepseek-v4-pro';
