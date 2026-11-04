/// Embedding 提供者测试（P1-4b）：fake http 验证端点/请求体/解析，
/// 以及所有失败路径都折叠成 null（回落语义召回的协议基础）。
library;

import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:dsh_pet_flutter/ai/embedding_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  group('OpenAiEmbeddingProvider', () {
    test('打 /embeddings：Bearer key、input 为数组、解析 data[0].embedding', () async {
      late http.Request captured;
      final provider = OpenAiEmbeddingProvider(
        baseUrl: 'https://api.example.com/v1/',
        model: 'text-embedding-3-small',
        keyLoader: () async => 'sk-test',
        client: MockClient((request) async {
          captured = request;
          return _json({
            'data': [
              {'embedding': [0.1, 0.2, 0.3]},
            ],
          });
        }),
      );

      final vector = await provider.embed('喜欢简洁回复');

      expect(captured.url.toString(), 'https://api.example.com/v1/embeddings');
      expect(captured.headers['Authorization'], 'Bearer sk-test');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['model'], 'text-embedding-3-small');
      expect(body['input'], ['喜欢简洁回复']);
      expect(vector, [0.1, 0.2, 0.3]);
    });

    test('缺 key / 空文本：直接 null，不发请求', () async {
      var requests = 0;
      final provider = OpenAiEmbeddingProvider(
        baseUrl: 'https://api.example.com/v1',
        model: 'text-embedding-3-small',
        keyLoader: () async => '',
        client: MockClient((_) async {
          requests++;
          return _json({});
        }),
      );

      expect(await provider.embed('文本'), isNull);
      expect(await provider.embed('  '), isNull);
      expect(requests, 0);
    });

    test('HTTP 4xx / 非 JSON / 向量缺字段：全部折叠成 null', () async {
      EmbeddingProvider build(http.Response Function() respond) =>
          OpenAiEmbeddingProvider(
            baseUrl: 'https://api.example.com/v1',
            model: 'text-embedding-3-small',
            keyLoader: () async => 'sk-test',
            client: MockClient((_) async => respond()),
          );

      expect(
        await build(() => _json({'error': 'boom'}, status: 401)).embed('文本'),
        isNull,
      );
      expect(
        await build(() => http.Response('<html>oops</html>', 200)).embed('文本'),
        isNull,
      );
      expect(await build(() => _json({'data': []})).embed('文本'), isNull);
      expect(
        await build(() => _json({
          'data': [
            {'embedding': [0.1, 'oops']},
          ],
        })).embed('文本'),
        isNull,
      );
    });
  });

  group('OllamaEmbeddingProvider', () {
    test('打 /api/embed：无鉴权头、input 为字符串、解析 embeddings[0]', () async {
      late http.Request captured;
      final provider = OllamaEmbeddingProvider(
        baseUrl: 'http://127.0.0.1:11434',
        model: 'bge-m3',
        client: MockClient((request) async {
          captured = request;
          return _json({
            'embeddings': [
              [1.0, 0.0],
            ],
          });
        }),
      );

      final vector = await provider.embed('作息早八');

      expect(captured.url.toString(), 'http://127.0.0.1:11434/api/embed');
      expect(captured.headers.containsKey('Authorization'), isFalse);
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['model'], 'bge-m3');
      expect(body['input'], '作息早八');
      expect(vector, [1.0, 0.0]);
    });

    test('网络异常/HTTP 错误/坏响应：null 且不抛出', () async {
      OllamaEmbeddingProvider build(MockClient client) =>
          OllamaEmbeddingProvider(
            baseUrl: 'http://127.0.0.1:11434',
            model: 'bge-m3',
            client: client,
          );

      expect(
        await build(
          MockClient((_) async => throw const SocketException('refused')),
        ).embed('文本'),
        isNull,
      );
      expect(
        await build(MockClient((_) async => _json({}, status: 500)))
            .embed('文本'),
        isNull,
      );
      expect(
        await build(MockClient((_) async => _json({'embeddings': []})))
            .embed('文本'),
        isNull,
      );
    });

    test('baseUrl 或 model 为空：null 且不发请求', () async {
      var requests = 0;
      final provider = OllamaEmbeddingProvider(
        baseUrl: '',
        model: '',
        client: MockClient((_) async {
          requests++;
          return _json({});
        }),
      );
      expect(await provider.embed('文本'), isNull);
      expect(requests, 0);
    });
  });

  group('DisabledEmbeddingProvider', () {
    test('恒 null：调用方免判空', () async {
      const provider = DisabledEmbeddingProvider();
      expect(await provider.embed('文本'), isNull);
      expect(provider.id, 'disabled');
    });
  });

  test('dispose 只关自建 client，外部传入的不动', () {
    var externalClosed = false;
    final provider = OpenAiEmbeddingProvider(
      baseUrl: 'https://api.example.com/v1',
      model: 'm',
      keyLoader: () async => 'sk',
      client: _TrackingClient(onClose: () => externalClosed = true),
    );
    provider.dispose();
    expect(externalClosed, isFalse);
  });
}

class _TrackingClient extends http.BaseClient {
  _TrackingClient({required this.onClose});

  final void Function() onClose;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(Stream.value(utf8.encode('{}')), 200);

  @override
  void close() => onClose();
}
