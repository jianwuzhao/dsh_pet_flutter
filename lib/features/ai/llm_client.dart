/// OpenAI 兼容 / Ollama 两路最小客户端。
///
/// 首期非流式：回复一次性返回，期间沿用现有 thinking 气泡/“思考中”提示。
/// 不伪造成功：未配置、缺 key、HTTP 错误、响应格式异常都返回结构化 Failure。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../core/config/ai_config.dart';
import '../../core/result.dart';

class AiMessage {
  const AiMessage({required this.role, required this.content});

  const AiMessage.user(this.content) : role = 'user';
  const AiMessage.assistant(this.content) : role = 'assistant';

  final String role;
  final String content;

  Map<String, dynamic> toJson() => {'role': role, 'content': content};

  factory AiMessage.fromJson(Map<String, dynamic> json) => AiMessage(
    role: json['role'] as String? ?? 'user',
    content: json['content'] as String? ?? '',
  );
}

class AiService {
  AiService({
    required this.config,
    required this.keyLoader,
    http.Client? client,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final AiConfig config;

  /// 每次请求时再读 key：设置页刚写入无需重建服务。
  final Future<String> Function() keyLoader;
  final http.Client _client;
  final bool _ownsClient;

  bool get canChat => config.enabled;

  Future<Result<String>> chat({
    required List<AiMessage> messages,
    String system = '',
  }) async {
    if (!config.enabled) {
      return const Failure('ai.disabled', '内置对话未启用：请在设置里选择提供者并填写模型');
    }
    final payload = <AiMessage>[
      if (system.trim().isNotEmpty)
        AiMessage(role: 'system', content: system.trim()),
      ...messages,
    ];
    try {
      if (config.isOpenAi) return await _openAi(payload);
      if (config.isOllama) return await _ollama(payload);
      return Failure('ai.provider', '不支持的 AI 提供者：${config.provider}');
    } on TimeoutException {
      return const Failure('ai.timeout', 'AI 请求超时（60 秒），请检查网络或服务端');
    } on SocketException catch (error) {
      return Failure('ai.network', '连不上 AI 服务：${error.message}');
    } on http.ClientException catch (error) {
      return Failure('ai.network', 'AI 请求失败：${error.message}');
    } on Object catch (error) {
      return Failure('ai.error', 'AI 请求异常：$error');
    }
  }

  Future<Result<String>> _openAi(List<AiMessage> messages) async {
    final key = (await keyLoader()).trim();
    if (key.isEmpty) {
      return const Failure('ai.no-key', 'OpenAI 兼容接口缺少 API Key：请在设置里填写');
    }
    final uri = Uri.parse('${_base()}/chat/completions');
    final response = await _client
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $key',
          },
          body: jsonEncode({
            'model': config.model,
            'messages': [for (final message in messages) message.toJson()],
            'temperature': 0.8,
          }),
        )
        .timeout(const Duration(seconds: 60));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return Failure(
        'ai.http-${response.statusCode}',
        'AI 服务返回 HTTP ${response.statusCode}：${_snippet(response.body)}',
      );
    }
    final content = _openAiContent(_decode(response.body));
    if (content.trim().isEmpty) {
      return const Failure('ai.empty', 'AI 返回了空回复');
    }
    return Success(content.trim());
  }

  Future<Result<String>> _ollama(List<AiMessage> messages) async {
    final uri = Uri.parse('${_base()}/api/chat');
    final response = await _client
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'model': config.model,
            'messages': [for (final message in messages) message.toJson()],
            'stream': false,
          }),
        )
        .timeout(const Duration(seconds: 60));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return Failure(
        'ai.http-${response.statusCode}',
        'Ollama 返回 HTTP ${response.statusCode}：${_snippet(response.body)}',
      );
    }
    final decoded = _decode(response.body);
    final message = decoded['message'];
    final content = message is Map ? message['content'] : null;
    if (content is! String || content.trim().isEmpty) {
      return const Failure('ai.empty', 'Ollama 返回了空回复');
    }
    return Success(content.trim());
  }

  String _base() {
    var base = config.baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base;
  }

  Map<String, dynamic> _decode(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
      throw const FormatException('响应不是 JSON 对象');
    } on FormatException catch (error) {
      throw FormatException('响应解析失败：$error');
    }
  }

  String _openAiContent(Map<String, dynamic> decoded) {
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) return '';
    final first = choices.first;
    if (first is! Map) return '';
    final message = first['message'];
    if (message is! Map) return '';
    final content = message['content'];
    if (content is String) return content;
    if (content is List) {
      // 新版 OpenAI 兼容服务可能返回 content parts。
      return [
        for (final part in content)
          if (part is Map && part['text'] is String) part['text'] as String,
      ].join();
    }
    return '';
  }

  String _snippet(String body) {
    final trimmed = body.trim().replaceAll(RegExp(r'\s+'), ' ');
    return trimmed.length <= 200 ? trimmed : '${trimmed.substring(0, 200)}…';
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}

/// 供设置页“测试连接”使用的轻量入口。
Future<Result<String>> testAiConnection(
  AiService service, {
  String system = '',
}) {
  return service.chat(
    messages: const [AiMessage.user('请只回复：连接成功')],
    system: system,
  );
}
