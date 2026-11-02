/// 路由：按配置选 active 提供者，不可用时逐级降级。
///
/// 降级链固定 openai → ollama → trae-bridge；trae 桥永远可用，
/// 所以“全部不可用”只可能是装配漏了桥，属于接线错误而非运行时状态。
library;

import 'llm_provider.dart';

class RouterResolution {
  const RouterResolution({
    required this.provider,
    required this.requestedId,
    required this.degraded,
  });

  final LlmProvider provider;

  /// 配置里想要的提供者 id（可能 == provider.id）。
  final String requestedId;

  /// true = 想要的不可用，实际用了降级链上的下一个。
  final bool degraded;

  /// 给气泡的一句话说明；未降级时为 null。
  String? get notice {
    if (!degraded) return null;
    if (requestedId.isEmpty) {
      return '未指定 AI 提供者，本次走 ${provider.displayName}';
    }
    return '「$requestedId」暂不可用，已降级为 ${provider.displayName}';
  }
}

class LlmRouter {
  LlmRouter({required this.providers, this.activeId = 'trae-bridge'});

  final List<LlmProvider> providers;

  /// config.ai.provider；'none' 视为“没想要谁”，直接走降级链兜底。
  String activeId;

  static const List<String> fallbackOrder = ['openai', 'ollama', 'trae-bridge'];

  LlmProvider? byId(String id) {
    for (final provider in providers) {
      if (provider.id == id) return provider;
    }
    return null;
  }

  /// 选出本次使用的提供者：active 可用就用 active，
  /// 否则按固定顺序找第一个可用的，并标记降级。
  Future<RouterResolution?> resolve() async {
    final requested = activeId == 'none' ? '' : activeId;
    if (requested.isNotEmpty) {
      final wanted = byId(requested);
      if (wanted != null && await wanted.isReady) {
        return RouterResolution(
          provider: wanted,
          requestedId: requested,
          degraded: false,
        );
      }
    }
    for (final id in fallbackOrder) {
      final candidate = byId(id);
      if (candidate != null && await candidate.isReady) {
        return RouterResolution(
          provider: candidate,
          requestedId: requested,
          degraded: true,
        );
      }
    }
    return null;
  }
}
