/// 交互网关：所有用户输入的唯一入口（面板 / 全局快捷键 / 事件服务）。
///
/// 职责只有“路由”：
/// - 会话服务接入后（supportsReply 的提供者），输入走对话路径并拿到回复；
/// - 否则维持现有转发行为——Dispatcher 投递到关联软件，外部链路完全不变。
library;

import '../ai/llm_provider.dart';
import '../ai/llm_router.dart';
import '../core/result.dart';
import '../features/linkage/assistant_adapters.dart';
import '../features/linkage/dispatcher.dart';

/// 输入来源：网关不区分行为，但后续学习层打反馈样本时要区分。
enum InputSource { panel, hotkey, eventServer }

/// 会话处理入口：人格 + 记忆 + 情绪组装后的对话调用。
/// M5 由 ConversationService 提供实现，M3 阶段保持转发行为。
typedef ConversationHandler = Future<Result<LlmReply>> Function(String prompt);

/// `/v2/chat` 的结构化回复：ok=false 时 reason 给出可读的降级/失败原因。
class GatewayChatReply {
  const GatewayChatReply({
    required this.ok,
    this.reply = '',
    this.reason = '',
    this.degraded = false,
    this.sentiment,
  });

  final bool ok;
  final String reply;

  /// 失败/降级原因；ok=true 且 degraded=false 时为空。
  final String reason;

  /// true = 想要的提供者不可用，回复来自降级链上的其他提供者。
  final bool degraded;

  /// 对话情绪标签（positive/negative/tired/excited/neutral），可空；
  /// 内核用它喂情绪引擎（计划 4.2 对话情绪感知）。
  final String? sentiment;
}

class InteractionGateway {
  InteractionGateway({
    required this.dispatcher,
    required this.router,
    ConversationHandler? conversation,
  }) : _conversation = conversation;

  /// 配置保存后由装配层整体替换（注册表随配置重建）。
  Dispatcher dispatcher;

  /// LLM 选路：activeId 跟随 config.ai.provider。
  LlmRouter router;

  ConversationHandler? _conversation;

  /// 接入会话服务（M5）：传入后 submit 的对话路径生效。
  set conversation(ConversationHandler? handler) => _conversation = handler;

  /// 唯一输入入口。空文本不外发，与 Dispatcher 的既有约定一致。
  /// 激活提供者支持直接回复时走对话服务（人格+记忆+情绪上下文），
  /// 否则维持转发到关联软件（计划 4.6）。
  Future<Result<DispatchOutcome>> submit(String text, InputSource source) async {
    final prompt = text.trim();
    if (prompt.isEmpty) {
      return const Failure('dispatch.empty', '内容为空，没有发送');
    }
    final handler = _conversation;
    if (handler != null && await _shouldConverse()) {
      return _submitConversation(handler, prompt);
    }
    return dispatcher.send(prompt);
  }

  /// 对话服务是否接管：激活提供者存在且支持直接回复。
  Future<bool> _shouldConverse() async {
    final resolution = await router.resolve();
    return resolution?.provider.supportsReply ?? false;
  }

  Future<Result<DispatchOutcome>> _submitConversation(
    ConversationHandler handler,
    String prompt,
  ) async {
    switch (await handler(prompt)) {
      case Success(value: final reply):
        if (reply.content.trim().isEmpty) {
          return const Failure('chat.empty', 'AI 返回了空回复');
        }
        return Success(DispatchOutcome(ok: true, reply: reply.content));
      case Failure(:final code, :final reason):
        return Failure(code, reason);
    }
  }

  /// `/v2/chat`：能回复的提供者直接回话；只剩转发能力时给明确原因，
  /// 不伪造成功，也不把 prompt 悄悄转发出去。
  Future<GatewayChatReply> chat(String text) async {
    final prompt = text.trim();
    if (prompt.isEmpty) {
      return const GatewayChatReply(ok: false, reason: '内容为空');
    }
    final resolution = await router.resolve();
    if (resolution == null) {
      return const GatewayChatReply(
        ok: false,
        reason: '没有可用的 AI 提供者：请在设置里配置 OpenAI 兼容接口或本地 Ollama',
      );
    }
    final provider = resolution.provider;
    if (!provider.supportsReply) {
      return GatewayChatReply(
        ok: false,
        // 明确告知「已降级到只转发」，别让调用方以为是原提供者坏了。
        degraded: resolution.degraded,
        reason: '当前提供者「${provider.displayName}」只支持转发到关联软件，不能直接回复',
      );
    }
    // 有对话服务时 `/v2/chat` 同样走人格+记忆+情绪上下文，与面板一致。
    final handler = _conversation;
    if (handler != null) {
      switch (await handler(prompt)) {
        case Success(value: final reply):
          return GatewayChatReply(
            ok: true,
            reply: reply.content,
            degraded: resolution.degraded,
            reason: resolution.notice ?? '',
            sentiment: reply.sentiment,
          );
        case Failure(:final code, :final reason):
          return GatewayChatReply(ok: false, reason: '[$code] $reason');
      }
    }
    switch (await provider.chat(
      LlmRequest(messages: [LlmMessage.user(prompt)]),
    )) {
      case Success(value: final reply):
        return GatewayChatReply(
          ok: true,
          reply: reply.content,
          degraded: resolution.degraded,
          reason: resolution.notice ?? '',
          sentiment: reply.sentiment,
        );
      case Failure(:final code, :final reason):
        return GatewayChatReply(ok: false, reason: '[$code] $reason');
    }
  }
}
