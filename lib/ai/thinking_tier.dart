/// 思考深度档位：把“要多深”抽象成三档，由模型编排按任务与预算选择。
///
/// 档位是**意图**，各 provider 负责把它翻译成自己支持的参数：
/// - OpenAI 兼容：`reasoning_effort`
/// - DeepSeek：`reasoning_effort` + `thinking.type`（不支持分级的后端用 system prompt 近似）
library;

enum ThinkingTier { fast, balanced, deep }

/// DeepSeek 官方 effort 映射（依据 api-docs.deepseek.com 思考模式文档）：
/// 官方默认 thinking 开启、effort 默认 high；
/// 传入值会被映射（medium→high、xhigh→high、ultra→max）。
///
/// - fast：关掉思考（省延迟与成本），effort 用最低档；
/// - balanced：思考开 + high（官方默认行为）；
/// - deep：思考开 + max。
({String effort, bool thinkingEnabled}) deepseekThinkingFor(ThinkingTier tier) =>
    switch (tier) {
      ThinkingTier.fast => (effort: 'low', thinkingEnabled: false),
      ThinkingTier.balanced => (effort: 'high', thinkingEnabled: true),
      ThinkingTier.deep => (effort: 'max', thinkingEnabled: true),
    };

/// OpenAI 兼容端点的 effort 映射（OpenAI 官方文档给的是 low/medium/high 语义，
/// 更高档位只在支持的服务上生效；这里保守映射到三档）。
String openAiEffortFor(ThinkingTier tier) => switch (tier) {
  ThinkingTier.fast => 'low',
  ThinkingTier.balanced => 'medium',
  ThinkingTier.deep => 'high',
};
