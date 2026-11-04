/// Embedding 提供者抽象（P1-4 语义召回）。
///
/// 与 LlmProvider 的 Result 协议不同，这里任何失败都折叠成 null：
/// embedding 只服务 Recall 的增强路径，失败 = 回落关键词召回，
/// 调用方无需区分失败原因，也就不值得为它建错误码体系。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

abstract class EmbeddingProvider {
  const EmbeddingProvider();

  String get id;

  /// 嵌入一段文本；null = 本次不可用，调用方回落关键词召回。
  Future<List<double>?> embed(String text);

  /// 释放自建资源（http client）；外部传入的 client 不归本类管。
  void dispose() {}
}

/// OpenAI 兼容端点：POST {baseUrl}/embeddings。
class OpenAiEmbeddingProvider extends EmbeddingProvider {
  OpenAiEmbeddingProvider({
    required String baseUrl,
    required String model,
    required this.keyLoader,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : _baseUrl = baseUrl.trim(),
       _model = model.trim(),
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  final String _baseUrl;
  final String _model;
  final Future<String> Function() keyLoader;
  final http.Client _client;
  final bool _ownsClient;

  /// 比 chat 的 60s 短得多：embedding 是对话前的辅助步骤，
  /// 卡满 60s 只会让用户觉得“没反应”，宁可早点回落关键词。
  final Duration timeout;

  @override
  String get id => 'openai';

  @override
  Future<List<double>?> embed(String text) async {
    final input = text.trim();
    if (input.isEmpty) return null;
    final key = (await keyLoader()).trim();
    if (key.isEmpty) return null;
    try {
      final response = await _client
          .post(
            Uri.parse('$_normalizedBase/embeddings'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $key',
            },
            body: jsonEncode({'model': _model, 'input': [input]}),
          )
          .timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return null;
      final data = decoded['data'];
      if (data is! List || data.isEmpty) return null;
      final first = data.first;
      return first is Map ? _vectorOf(first['embedding']) : null;
    } on Object {
      // 超时/网络/解析失败统一折叠：调用方只认 null。
      return null;
    }
  }

  String get _normalizedBase {
    var base = _baseUrl;
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base;
  }

  @override
  void dispose() {
    if (_ownsClient) _client.close();
  }
}

/// 本地 Ollama：POST {baseUrl}/api/embed，无需 key。
class OllamaEmbeddingProvider extends EmbeddingProvider {
  OllamaEmbeddingProvider({
    required String baseUrl,
    required String model,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : _baseUrl = baseUrl.trim(),
       _model = model.trim(),
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  final String _baseUrl;
  final String _model;
  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;

  @override
  String get id => 'ollama';

  @override
  Future<List<double>?> embed(String text) async {
    final input = text.trim();
    if (input.isEmpty || _baseUrl.isEmpty || _model.isEmpty) return null;
    try {
      final response = await _client
          .post(
            Uri.parse('$_normalizedBase/api/embed'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'model': _model, 'input': input}),
          )
          .timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return null;
      return _vectorOf(decoded['embeddings']?[0]);
    } on Object {
      return null;
    }
  }

  String get _normalizedBase {
    var base = _baseUrl;
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base;
  }

  @override
  void dispose() {
    if (_ownsClient) _client.close();
  }
}

/// 配置关闭/缺失时的占位：恒返回 null，语义召回自然回落关键词，
/// 让调用方免判空。
class DisabledEmbeddingProvider extends EmbeddingProvider {
  const DisabledEmbeddingProvider();

  @override
  String get id => 'disabled';

  @override
  Future<List<double>?> embed(String text) async => null;
}

/// 响应里的向量字段解析：非空且全为数值才算合法，
/// 中途遇到非数值项整体作废（宁可回落也不嵌脏数据进向量库）。
List<double>? _vectorOf(Object? raw) {
  if (raw is! List || raw.isEmpty) return null;
  final vector = <double>[];
  for (final item in raw) {
    if (item is! num) return null;
    vector.add(item.toDouble());
  }
  return vector;
}
