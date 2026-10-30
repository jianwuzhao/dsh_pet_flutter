/// 本地事件服务：让 Trae CN 的 skill / petctl / 自动化脚本把状态与 thinking 推给桌宠。
///
/// 只监听回环地址 + Bearer token：桌宠能看到用户正在处理的代码与对话，
/// 不能把这条通道暴露到局域网。token 落 0600 文件，CLI 与 skill 都从这里读。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../core/paths/app_paths.dart';
import '../../../platform/pet_platform.dart';
import 'bridge_hub.dart';
import 'status/assistant_event.dart';

class PetEventServer {
  PetEventServer({
    required this.port,
    required this.onEvent,
    required this.onDispatch,
    required this.hub,
    required this.platform,
    this.petState,
  });

  final int port;
  final void Function(AssistantEvent event) onEvent;
  final Future<String> Function(String prompt) onDispatch;

  /// Trae 扩展桥：轮询取消息 + 回执。
  final BridgeHub hub;

  /// 窗口控制：/window/* 诊断端点用。宠物窗口被藏到找不回时，
  /// curl 一条命令拉回来，也方便远程验证“隐藏→显示”不再失灵。
  final PetPlatform platform;

  /// 宠物内部坐标/屏幕快照：/pet/state 用，排查“拖不动 / 跑到另一块屏”。
  final Map<String, Object?> Function()? petState;

  HttpServer? _server;
  WebSocket? _streamSocket;
  String _token = '';

  int get actualPort => _server?.port ?? port;
  String get token => _token;

  static Future<String> ensureToken() async {
    AppPaths.ensure();
    final file = AppPaths.tokenFile;
    if (file.existsSync()) {
      final existing = file.readAsStringSync().trim();
      if (existing.isNotEmpty) return existing;
    }
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    final token = base64Url.encode(bytes).replaceAll('=', '');
    file.writeAsStringSync(token);
    // 只有当前用户可读：token 等价于桌宠的写权限。
    await Process.run('chmod', ['600', file.path]);
    return token;
  }

  Future<String?> start() async {
    try {
      _token = await ensureToken();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      _server = server;
      server.listen(
        _handle,
        onError: (Object error) {
          debugPrint('事件服务错误: $error');
        },
      );
      return null;
    } on Object catch (error) {
      return '事件服务启动失败（端口 $port）：$error';
    }
  }

  Future<void> stop() async {
    await _streamSocket?.close();
    await _server?.close(force: true);
    _server = null;
  }

  bool _authorized(HttpRequest request) {
    final header = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    if (header == 'Bearer $_token') return true;
    // WebSocket 浏览器端无法自定义头部，允许查询参数，但同样比对同一个 token。
    return request.uri.queryParameters['token'] == _token;
  }

  Future<void> _handle(HttpRequest request) async {
    if (!_authorized(request)) {
      request.response.statusCode = HttpStatus.unauthorized;
      request.response.write('unauthorized');
      await request.response.close();
      return;
    }

    switch (request.uri.path) {
      case '/health':
        _json(request.response, {'ok': true, 'port': actualPort});
        return;
      case '/event':
        if (request.method != 'POST') {
          _json(request.response, {
            'ok': false,
            'reason': '只接受 POST',
          }, status: 405);
          return;
        }
        await _handleEvent(request);
        return;
      case '/dispatch':
        if (request.method != 'POST') {
          _json(request.response, {
            'ok': false,
            'reason': '只接受 POST',
          }, status: 405);
          return;
        }
        await _handleDispatch(request);
        return;
      case '/bridge/pending':
        // Trae 扩展轮询待发消息；GET 才合理，其余按 405 处理。
        if (request.method != 'GET') {
          _json(request.response, {
            'ok': false,
            'reason': '只接受 GET',
          }, status: 405);
          return;
        }
        final adapter = request.uri.queryParameters['adapter'] ?? '';
        if (adapter.isEmpty) {
          _json(request.response, {
            'ok': false,
            'reason': '缺少 adapter',
          }, status: 400);
          return;
        }
        final prompts = hub.drain(adapter);
        _json(request.response, {
          'ok': true,
          'prompts': [for (final prompt in prompts) prompt.toJson()],
        });
        return;
      case '/bridge/ack':
        if (request.method != 'POST') {
          _json(request.response, {
            'ok': false,
            'reason': '只接受 POST',
          }, status: 405);
          return;
        }
        await _handleBridgeAck(request);
        return;
      case '/bridge/state':
        // 诊断端点：扩展有没有在轮询、队列有没有积压，petctl bridge 直接看。
        if (request.method != 'GET') {
          _json(request.response, {
            'ok': false,
            'reason': '只接受 GET',
          }, status: 405);
          return;
        }
        _json(request.response, {'ok': true, ...hub.snapshot()});
        return;
      case '/window/state':
        if (request.method != 'GET') {
          _json(request.response, {
            'ok': false,
            'reason': '只接受 GET',
          }, status: 405);
          return;
        }
        final diagnostics = await platform.windowDiagnostics();
        _json(request.response, {'ok': true, ...?diagnostics});
        return;
      case '/pet/state':
        // 诊断端点：宠物内部坐标、活动屏幕、拖拽域。多屏拖不动时先看这里。
        if (request.method != 'GET') {
          _json(request.response, {
            'ok': false,
            'reason': '只接受 GET',
          }, status: 405);
          return;
        }
        _json(request.response, {'ok': true, ...?petState?.call()});
        return;
      case '/window/show':
        if (request.method != 'POST') {
          _json(request.response, {
            'ok': false,
            'reason': '只接受 POST',
          }, status: 405);
          return;
        }
        await platform.showWindow();
        _json(request.response, {
          'ok': true,
          'visible': await platform.isWindowVisible(),
        });
        return;
      case '/window/hide':
        if (request.method != 'POST') {
          _json(request.response, {
            'ok': false,
            'reason': '只接受 POST',
          }, status: 405);
          return;
        }
        await platform.hideWindow();
        _json(request.response, {
          'ok': true,
          'visible': await platform.isWindowVisible(),
        });
        return;
      case '/stream':
        if (!WebSocketTransformer.isUpgradeRequest(request)) {
          _json(request.response, {
            'ok': false,
            'reason': '需要 WebSocket 升级',
          }, status: 400);
          return;
        }
        final socket = await WebSocketTransformer.upgrade(request);
        _streamSocket = socket;
        socket.listen(
          (data) => _handleStreamFrame(data),
          onDone: () {
            if (identical(_streamSocket, socket)) _streamSocket = null;
          },
        );
        return;
      default:
        _json(request.response, {'ok': false, 'reason': '未知路径'}, status: 404);
    }
  }

  void _handleStreamFrame(Object? data) {
    if (data is! String) return;
    final event = _parse(data);
    if (event != null) onEvent(event);
  }

  Future<void> _handleEvent(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final event = _parse(body);
    if (event == null) {
      _json(request.response, {
        'ok': false,
        'reason': '事件 JSON 非法',
      }, status: 400);
      return;
    }
    onEvent(event);
    _json(request.response, {'ok': true});
  }

  Future<void> _handleDispatch(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (error) {
      _json(request.response, {
        'ok': false,
        'reason': 'JSON 非法：$error',
      }, status: 400);
      return;
    }
    final prompt = decoded is Map ? decoded['text'] as String? : null;
    if (prompt == null || prompt.trim().isEmpty) {
      _json(request.response, {'ok': false, 'reason': '缺少 text'}, status: 400);
      return;
    }
    final String reason;
    try {
      reason = await onDispatch(prompt);
    } on Object catch (error) {
      _json(request.response, {
        'ok': false,
        'reason': '投递异常：$error',
      }, status: 500);
      return;
    }
    _json(request.response, {'ok': reason.isEmpty, 'reason': reason});
  }

  Future<void> _handleBridgeAck(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (error) {
      _json(request.response, {
        'ok': false,
        'reason': 'JSON 非法：$error',
      }, status: 400);
      return;
    }
    final map = decoded is Map ? decoded : null;
    final id = map?['id'];
    if (map == null || id is! int) {
      _json(request.response, {'ok': false, 'reason': '缺少 id'}, status: 400);
      return;
    }
    final message = map['message'];
    hub.completeAck(
      id,
      (map['ok'] as bool?) ?? false,
      message is String ? message : '',
    );
    _json(request.response, {'ok': true});
  }

  AssistantEvent? _parse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return AssistantEvent.fromJson(decoded);
    } on FormatException {
      return null;
    }
  }

  void _json(
    HttpResponse response,
    Map<String, Object?> payload, {
    int status = 200,
  }) {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(payload));
    response.close();
  }
}
