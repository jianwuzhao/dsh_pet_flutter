/// AI 软件适配器：识别是否在用它、把宠物里的输入投递过去。
///
/// WorkBuddy 没有公开协议（本机也未安装），因此它走“通用可配置”形态：
/// 填 bundleId / uriTemplate / delivery / endpoint 即可接入，不写死任何猜测行为。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/config/app_config.dart';
import '../../core/result.dart';
import '../../platform/pet_platform.dart';
import '../ai/chat_memory.dart';
import '../ai/llm_client.dart';
import 'bridge_hub.dart';

class DispatchOutcome {
  const DispatchOutcome({
    required this.ok,
    this.code = '',
    this.reason = '',
    this.reply = '',
  });

  final bool ok;
  final String code;
  final String reason;

  /// 内置对话的助手回复；外置投递为空。
  final String reply;

  static const DispatchOutcome success = DispatchOutcome(ok: true);
}

abstract class AssistantAdapter {
  AssistantAdapter(this.config, this.platform);

  final AdapterConfig config;
  final PetPlatform platform;

  String get id => config.id;
  String get displayName => config.displayName;

  /// 前台应用是否属于本适配器。
  bool matchesApp(String bundleId, String appName) {
    if (config.bundleId.isNotEmpty && bundleId == config.bundleId) return true;
    if (config.appName.isEmpty) return false;
    return appName.toLowerCase().contains(config.appName.toLowerCase());
  }

  /// 把用户输入投递到该软件的会话。
  Future<DispatchOutcome> dispatch(String prompt);
}

class TraeCnAdapter extends AssistantAdapter {
  TraeCnAdapter(super.config, super.platform, [this._hub]);

  final BridgeHub? _hub;

  @override
  Future<DispatchOutcome> dispatch(String prompt) async {
    // 桥接扩展在 Trae 进程里直接执行 workbench.action.chat.open，
    // 不需要辅助功能授权；扩展不在（桥未存活）才退回剪贴板注入。
    final hub = _hub;
    if (hub != null && hub.isAlive(id)) {
      await platform.activateApp(config.bundleId);
      final ack = await hub.send(id, prompt);
      if (ack.ok) return DispatchOutcome.success;
      if (ack.timedOut) {
        return const DispatchOutcome(
          ok: false,
          code: 'dispatch.bridge-timeout',
          reason: 'Trae 桥接插件 8 秒内没有来取消息：Trae 可能刚重启或扩展停了，稍后再试',
        );
      }
      return DispatchOutcome(
        ok: false,
        code: 'dispatch.bridge-rejected',
        reason:
            'Trae 桥接插件投递失败：'
            '${ack.message.isEmpty ? 'workbench.action.chat.open 执行出错' : ack.message}',
      );
    }
    return _dispatchThroughApp(
      config,
      platform,
      prompt,
      appFallbackUri: 'trae-cn://',
    );
  }
}

class ChatGptAdapter extends AssistantAdapter {
  ChatGptAdapter(super.config, super.platform);

  @override
  Future<DispatchOutcome> dispatch(String prompt) =>
      _dispatchThroughApp(config, platform, prompt, appFallbackUri: 'codex://');
}

class WorkBuddyAdapter extends AssistantAdapter {
  WorkBuddyAdapter(super.config, super.platform);

  @override
  Future<DispatchOutcome> dispatch(String prompt) async {
    if (config.delivery == DeliveryMode.http ||
        config.delivery == DeliveryMode.ws) {
      return _postToEndpoint(config, prompt);
    }
    if (config.bundleId.isEmpty &&
        config.uriTemplate.isEmpty &&
        config.endpoint.isEmpty) {
      return const DispatchOutcome(
        ok: false,
        code: 'workbuddy.not-configured',
        reason: 'WorkBuddy 未配置接入（设置页填 bundleId / uriTemplate / endpoint 任一即可）',
      );
    }
    return _dispatchThroughApp(config, platform, prompt, appFallbackUri: '');
  }
}

/// 内置对话：不依赖任何外部软件，走用户自备的 OpenAI 兼容 / Ollama 接口。
class BuiltinAdapter extends AssistantAdapter {
  BuiltinAdapter(
    super.config,
    super.platform, {
    this.ai,
    this.memory,
    this.persona = '',
  });

  final AiService? ai;
  final ChatMemory? memory;
  final String persona;

  @override
  Future<DispatchOutcome> dispatch(String prompt) async {
    final service = ai;
    if (service == null || !service.canChat) {
      return const DispatchOutcome(
        ok: false,
        code: 'builtin.not-configured',
        reason: '内置对话未启用：请在设置里选择 OpenAI 兼容或 Ollama，并填写模型',
      );
    }
    final history = memory?.context(service.config.memoryRounds) ?? const [];
    final result = await service.chat(
      messages: [...history, AiMessage.user(prompt)],
      system: persona,
    );
    switch (result) {
      case Success(value: final reply):
        if (reply.trim().isEmpty) {
          return const DispatchOutcome(
            ok: false,
            code: 'builtin.empty',
            reason: '内置对话返回了空回复',
          );
        }
        memory?.appendRound(prompt, reply);
        return DispatchOutcome(ok: true, reply: reply);
      case Failure(code: final code, reason: final reason):
        return DispatchOutcome(ok: false, code: code, reason: reason);
    }
  }
}

/// 投递入口：原生侧拒绝（如未授权辅助功能）会抛 PlatformException，
/// 这里统一折成结构化失败，既不会假装成功，也不会让调用方看到裸异常。
Future<DispatchOutcome> _dispatchThroughApp(
  AdapterConfig config,
  PetPlatform platform,
  String prompt, {
  required String appFallbackUri,
}) async {
  try {
    return await _deliverThroughApp(
      config,
      platform,
      prompt,
      appFallbackUri: appFallbackUri,
    );
  } on PlatformException catch (error) {
    return DispatchOutcome(
      ok: false,
      code: error.code,
      reason: error.message ?? '与系统交互失败：${error.code}',
    );
  } on Object catch (error) {
    return DispatchOutcome(
      ok: false,
      code: 'dispatch.error',
      reason: '投递到 ${config.displayName} 失败：$error',
    );
  }
}

Future<DispatchOutcome> _deliverThroughApp(
  AdapterConfig config,
  PetPlatform platform,
  String prompt, {
  required String appFallbackUri,
}) async {
  final uri = config.uriTemplate.trim();
  if (config.delivery == DeliveryMode.uri && uri.isNotEmpty) {
    final target = uri.contains('{prompt}')
        ? uri.replaceAll('{prompt}', Uri.encodeComponent(prompt))
        : uri;
    final opened = await platform.openUrl(target);
    if (!opened) {
      return DispatchOutcome(
        ok: false,
        code: 'dispatch.uri-failed',
        reason: '打不开深链：$target',
      );
    }
    return DispatchOutcome.success;
  }

  // 剪贴板 + 激活 + ⌘V 回车：对方没有公开“发消息”接口时最可靠的路径。
  await Clipboard.setData(ClipboardData(text: prompt));
  final activated =
      config.bundleId.isEmpty || await platform.activateApp(config.bundleId);
  if (!activated) {
    if (appFallbackUri.isNotEmpty) {
      await platform.openUrl(appFallbackUri);
    }
    return DispatchOutcome(
      ok: false,
      code: 'dispatch.app-not-running',
      reason: '${config.displayName} 未运行：已把它唤起，请手动粘贴（内容已在剪贴板）',
    );
  }
  final pasted = await platform.pasteAndSubmit();
  if (!pasted) {
    return DispatchOutcome(
      ok: false,
      code: 'dispatch.inject-denied',
      reason: '已复制到剪贴板并切到 ${config.displayName}，但缺少“辅助功能”授权，无法自动粘贴发送',
    );
  }
  return DispatchOutcome.success;
}

Future<DispatchOutcome> _postToEndpoint(
  AdapterConfig config,
  String prompt,
) async {
  if (config.endpoint.isEmpty) {
    return const DispatchOutcome(
      ok: false,
      code: 'adapter.no-endpoint',
      reason: '适配器没有配置 endpoint，无法投递',
    );
  }
  final client = HttpClient();
  try {
    if (config.delivery == DeliveryMode.ws) {
      final socket = await WebSocket.connect(config.endpoint);
      socket.add(jsonEncode({'type': 'prompt', 'text': prompt}));
      await socket.close();
      return DispatchOutcome.success;
    }
    final request = await client.postUrl(Uri.parse(config.endpoint));
    request.headers.contentType = ContentType.json;
    if (config.token.isNotEmpty) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${config.token}',
      );
    }
    request.write(jsonEncode({'type': 'prompt', 'text': prompt}));
    final response = await request.close();
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return DispatchOutcome.success;
    }
    return DispatchOutcome(
      ok: false,
      code: 'adapter.http-${response.statusCode}',
      reason: '${config.displayName} 返回 HTTP ${response.statusCode}',
    );
  } on Object catch (error) {
    return DispatchOutcome(
      ok: false,
      code: 'adapter.http-error',
      reason: '投递到 ${config.displayName} 失败：$error',
    );
  } finally {
    client.close(force: true);
  }
}

class AdapterRegistry {
  AdapterRegistry(this._adapters);

  /// 按配置建注册表：未知 id（用户自定义的软件）统一走 WorkBuddyAdapter 的通用可配置路径。
  factory AdapterRegistry.fromConfig(
    LinkageConfig linkage,
    PetPlatform platform, {
    BridgeHub? bridgeHub,
    AiService? ai,
    ChatMemory? memory,
    String persona = '',
  }) {
    AssistantAdapter build(AdapterConfig config) => switch (config.id) {
      'trae-cn' => TraeCnAdapter(config, platform, bridgeHub),
      'chatgpt' => ChatGptAdapter(config, platform),
      'builtin' => BuiltinAdapter(
        config,
        platform,
        ai: ai,
        memory: memory,
        persona: persona,
      ),
      _ => WorkBuddyAdapter(config, platform),
    };
    return AdapterRegistry({
      for (final config in linkage.adapters.values) config.id: build(config),
    });
  }

  final Map<String, AssistantAdapter> _adapters;

  Iterable<AssistantAdapter> get all => _adapters.values;

  AssistantAdapter? byId(String id) => _adapters[id];

  AssistantAdapter? matchApp(String bundleId, String appName) {
    for (final adapter in _adapters.values) {
      if (adapter.matchesApp(bundleId, appName)) return adapter;
    }
    return null;
  }

  Future<Result<DispatchOutcome>> dispatch(String prompt, {String? id}) async {
    final adapter =
        (id == null ? null : _adapters[id]) ?? _adapters.values.firstOrNull;
    if (adapter == null) {
      return const Failure('dispatch.no-adapter', '还没有配置任何关联软件');
    }
    final outcome = await adapter.dispatch(prompt);
    return Success(outcome);
  }
}
