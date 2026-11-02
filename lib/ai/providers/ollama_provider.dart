/// 本地 Ollama 提供者：POST {baseUrl}/api/chat，无需 key。
///
/// isReady 不是纯配置检查：会探测 `{baseUrl}/api/tags`（Ollama 的标准
/// 元信息端点，很轻），避免把「配置填了但服务没跑」的后端选进降级链——
/// 否则对话会白等满 60 秒才超时。
/// 探活结果按 [probeTtl] 缓存，避免每次输入都打一次请求；
/// 配置只在装配时传入、之后不可变，所以缓存键就是实例本身。
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
    this.probeTimeout = const Duration(milliseconds: 1200),
    this.probeTtl = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : _baseUrl = baseUrl.trim(),
       _model = model.trim(),
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _clock = clock ?? DateTime.now;

  final String _baseUrl;
  final String _model;
  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _clock;

  /// 探活超时：只判断「端口通不通」，不该拖慢任何一次输入。
  final Duration probeTimeout;

  /// 探活结果缓存时长：Ollama 起停是低频事件，30s 足够且不会频繁请求。
  final Duration probeTtl;

  bool? _readyCache;
  DateTime? _readyCheckedAt;

  @override
  String get id => 'ollama';

  @override
  String get displayName => '本地 Ollama';

  @override
  bool get supportsReply => true;

  @override
  Future<bool> get isReady async {
    // 参数不全直接否，连探活都省掉。
    if (_baseUrl.isEmpty || _model.isEmpty) return false;
    final cached = _readyCache;
    final checkedAt = _readyCheckedAt;
    if (cached != null &&
        checkedAt != null &&
        _clock().difference(checkedAt) < probeTtl) {
      return cached;
    }
    final ready = await _probe();
    _readyCache = ready;
    _readyCheckedAt = _clock();
    return ready;
  }

  /// 轻量探活：GET /api/tags，2xx 才算服务在线。
  /// 网络错误/超时一律视为不可用——降级链据此跳过本提供者。
  Future<bool> _probe() async {
    try {
      final response = await _client
          .get(Uri.parse('$_normalizedBase/api/tags'))
          .timeout(probeTimeout);
      return response.statusCode >= 200 && response.statusCode < 300;
    } on TimeoutException {
      return false;
    } on SocketException {
      return false;
    } on Object {
      return false;
    }
  }

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
      Map<String, dynamic> decoded;
      try {
        final raw = jsonDecode(response.body);
        if (raw is! Map<String, dynamic>) {
          return const Failure('ai.malformed', 'Ollama 返回了无法解析的回复');
        }
        decoded = raw;
      } on FormatException catch (error) {
        return Failure('ai.malformed', 'Ollama 返回了无法解析的响应：${error.message}');
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

  @override
  void dispose() {
    if (_ownsClient) _client.close();
  }
}
