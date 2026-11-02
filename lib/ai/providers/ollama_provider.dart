/// 本地 Ollama 提供者：POST {baseUrl}/api/chat，无需 key。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../core/result.dart';
import '../llm_provider.dart';

class OllamaProvider extends LlmProvider {
  OllamaProvider({
    required String baseUrl,
    required String model,
    http.Client? client,
  }) : _baseUrl = baseUrl.trim(),
       _model = model.trim(),
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  final String _baseUrl;
  final String _model;
  final http.Client _client;
  final bool _ownsClient;

  @override
  String get id => 'ollama';

  @override
  String get displayName => '本地 Ollama';

  @override
  bool get supportsReply => true;

  @override
  Future<bool> get isReady async => _baseUrl.isNotEmpty && _model.isNotEmpty;

  @override
  Future<Result<LlmReply>> chat(LlmRequest request) async {
    try {
      final response = await _client
          .post(
            Uri.parse('$_normalizedBase/api/chat'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'model': _model,
              'messages': [
                for (final message in request.payload) message.toJson(),
              ],
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
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return const Failure('ai.empty', 'Ollama 返回了无法解析的回复');
      }
      final message = decoded['message'];
      final content = message is Map ? message['content'] : null;
      if (content is! String || content.trim().isEmpty) {
        return const Failure('ai.empty', 'Ollama 返回了空回复');
      }
      return Success(LlmReply.parse(content));
    } on TimeoutException {
      return const Failure('ai.timeout', 'AI 请求超时（60 秒），请检查本地模型是否在跑');
    } on SocketException catch (error) {
      return Failure('ai.network', '连不上 Ollama：${error.message}');
    }
  }

  String get _normalizedBase {
    var base = _baseUrl;
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base;
  }

  String _snippet(String body) {
    final trimmed = body.trim().replaceAll(RegExp(r'\s+'), ' ');
    return trimmed.length <= 200 ? trimmed : '${trimmed.substring(0, 200)}…';
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
