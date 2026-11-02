/// OpenAI 兼容提供者：POST {baseUrl}/chat/completions，首期非流式。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../core/result.dart';
import '../llm_provider.dart';
import '../thinking_tier.dart';

class OpenAiProvider extends LlmProvider {
  OpenAiProvider({
    required String baseUrl,
    required String model,
    required this.keyLoader,
    http.Client? client,
  }) : _baseUrl = baseUrl.trim(),
       _model = model.trim(),
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  final String _baseUrl;
  final String _model;

  /// 每次请求再读 key：设置页刚写入无需重建提供者。
  final Future<String> Function() keyLoader;
  final http.Client _client;
  final bool _ownsClient;

  @override
  String get id => 'openai';

  @override
  String get displayName => 'OpenAI 兼容';

  @override
  bool get supportsReply => true;

  @override
  Future<bool> get isReady async =>
      _baseUrl.isNotEmpty &&
      _model.isNotEmpty &&
      (await keyLoader()).trim().isNotEmpty;

  /// 子类可补充请求体字段（如 DeepSeek 的 thinking / reasoning_effort）。
  /// 返回空表时请求体与纯 OpenAI 兼容端点完全一致。
  Map<String, dynamic> requestExtras(ThinkingTier tier) => const {};

  @override
  Future<Result<LlmReply>> chat(LlmRequest request) async {
    final key = (await keyLoader()).trim();
    if (key.isEmpty) {
      return const Failure('ai.no-key', 'OpenAI 兼容接口缺少 API Key：请在设置里填写');
    }
    try {
      final response = await _client
          .post(
            Uri.parse('$_normalizedBase/chat/completions'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $key',
            },
            body: jsonEncode({
              'model': _model,
              'messages': [
                for (final message in request.payload) message.toJson(),
              ],
              // provider 特有参数（如 DeepSeek 的 thinking/reasoning_effort）。
              ...requestExtras(request.thinkingTier),
            }),
          )
          .timeout(const Duration(seconds: 60));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return Failure(
          'ai.http-${response.statusCode}',
          'AI 服务返回 HTTP ${response.statusCode}：${_snippet(response.body)}',
        );
      }
      Map<String, dynamic> decoded;
      try {
        decoded = _decode(response.body);
      } on FormatException catch (error) {
        return Failure('ai.malformed', 'AI 服务返回了无法解析的响应：${error.message}');
      }
      final content = _content(decoded);
      if (content.trim().isEmpty) {
        return const Failure('ai.empty', 'AI 返回了空回复');
      }
      return Success(LlmReply.parse(content));
    } on TimeoutException {
      return const Failure('ai.timeout', 'AI 请求超时（60 秒），请检查网络或服务端');
    } on SocketException catch (error) {
      return Failure('ai.network', '连不上 AI 服务：${error.message}');
    }
  }

  String get _normalizedBase {
    var base = _baseUrl;
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base;
  }

  Map<String, dynamic> _decode(String body) {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    throw const FormatException('响应不是 JSON 对象');
  }

  String _content(Map<String, dynamic> decoded) {
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

  @override
  void dispose() {
    if (_ownsClient) _client.close();
  }
}
