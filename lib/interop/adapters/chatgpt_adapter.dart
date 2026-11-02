/// ChatGPT 能力适配器（与联动层的投递适配器同名不同职责，故加 Capability 后缀）。
///
/// 探测只看“有没有可用的 API Key + 参数是否齐全”，不发任何请求；
/// 真正调用在 M2 接 Responses 方向时实现。
library;

import 'dart:io';

import '../capability.dart';

class ChatGptCapability extends ProbeOnlyAdapter {
  ChatGptCapability({
    required Future<String> Function() keyLoader,
    String? baseUrl,
    String? model,
    List<String>? appPaths,
  }) : _keyLoader = keyLoader,
       _baseUrl = (baseUrl ?? '').trim(),
       _model = (model ?? '').trim(),
       _appPaths = appPaths ?? const ['/Applications/ChatGPT.app'];

  final Future<String> Function() _keyLoader;
  final String _baseUrl;
  final String _model;
  final List<String> _appPaths;

  @override
  CapabilityDescriptor get descriptor => const CapabilityDescriptor(
    id: 'chatgpt',
    displayName: 'ChatGPT',
    kinds: {CapabilityKind.chat, CapabilityKind.deepResearch},
    mode: AccessMode.officialApi,
    requiresAccount: true,
    requiresApproval: true,
  );

  @override
  Future<Availability> probe({Duration? timeout}) async {
    final String key;
    try {
      key = (await _keyLoader()).trim();
    } on Object catch (error) {
      return Availability.unreachable('读取 API Key 失败：$error');
    }

    final installed = _appPaths.any((path) => Directory(path).existsSync());
    final installedNote = installed ? '（本机已安装桌面客户端，但仅作参考）' : '';

    if (key.isEmpty) {
      return Availability.notConfigured(
        '未配置 OpenAI API Key',
        detail: '设置 › 大脑 里填写 API Key 后可启用官方 API 调用$installedNote',
      );
    }
    if (_baseUrl.isEmpty || _model.isEmpty) {
      return Availability.notConfigured(
        'API Key 已配置，但 Base URL 或模型为空',
        detail: '请到设置 › 大脑 补齐参数$installedNote',
      );
    }
    return Availability.readyNow(
      '官方 API 参数齐全，可用于对话与深度研究',
      detail: '$_baseUrl · $_model$installedNote',
    );
  }
}
