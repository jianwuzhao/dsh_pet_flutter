/// LLM 提供者抽象：AI 能力层的出口协议。
///
/// 三路实现见 providers/：OpenAI 兼容云 API、本地 Ollama、Trae 桥（只转发）。
/// 网关层只看 `supportsReply` 决定走会话服务还是转发，不关心具体后端。
library;

import '../core/result.dart';

/// 会话消息：role ∈ system/user/assistant。
class LlmMessage {
  const LlmMessage({required this.role, required this.content});

  const LlmMessage.user(this.content) : role = 'user';
  const LlmMessage.assistant(this.content) : role = 'assistant';

  final String role;
  final String content;

  Map<String, dynamic> toJson() => {'role': role, 'content': content};
}

class LlmRequest {
  const LlmRequest({required this.messages, this.system = ''});

  final List<LlmMessage> messages;

  /// 系统提示（人格 DNA + 情绪摘要 + 记忆上下文由会话服务拼好放这里）。
  final String system;

  /// 实际下发的消息序列：system 非空时排最前。
  List<LlmMessage> get payload => [
    if (system.trim().isNotEmpty)
      LlmMessage(role: 'system', content: system.trim()),
    ...messages,
  ];
}

class LlmReply {
  const LlmReply({required this.content, this.sentiment});

  /// 模型回复正文。
  final String content;

  /// 对话情绪标签（positive/negative/tired/excited/neutral），
  /// 由会话服务在 system prompt 里约定的首行标记解析而来，可空。
  final String? sentiment;

  /// 情绪标记协议：模型被要求把回复写成
  /// `[[sentiment:positive]]\n正文`；这里剥掉标记得到正文与标签。
  /// 没有标记就当普通回复（sentiment=null，走关键词启发式兜底）。
  static LlmReply parse(String raw) {
    final match = RegExp(
      r'^\s*\[\[sentiment:([a-z]+)\]\]\s*\n?',
    ).firstMatch(raw);
    if (match == null) return LlmReply(content: raw.trim());
    return LlmReply(
      content: raw.substring(match.end).trim(),
      sentiment: match.group(1),
    );
  }
}

abstract class LlmProvider {
  const LlmProvider();

  /// 配置里的 provider 标识：openai / ollama / trae-bridge。
  String get id;

  String get displayName;

  /// false = 只能送出收不到回复（trae 桥），网关据此改走转发路径。
  bool get supportsReply;

  /// 配置齐全（含 key 这类要异步读的秘密）才可被路由选为 active。
  Future<bool> get isReady;

  Future<Result<LlmReply>> chat(LlmRequest request);

  /// 释放提供者持有的资源（自建的 http.Client 等）。
  /// 默认无资源可释放；持有自建客户端的实现必须覆写，
  /// 否则经抽象类型持有的一方无法正确关闭连接池。
  void dispose() {}
}
