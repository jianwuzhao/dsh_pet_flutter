/// WorkBuddy 能力适配器（与联动层的投递适配器同名不同职责，故加 Capability 后缀）。
///
/// 现实接法（调研结论）：个人版只有桌面客户端 + IM 远程下发，无开放 API；
/// 企业版（WorkBuddy Enterprise，腾讯云）提供 Managed Agents REST API 与
/// 本地 `--serve` HTTP API（127.0.0.1:8080）。M1 只探测“本机有没有可用的
/// 本地 API 或客户端”，不发任务。
library;

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../capability.dart';

class WorkBuddyCapability extends ProbeOnlyAdapter {
  WorkBuddyCapability({
    List<String>? appPaths,
    Uri? localApiBase,
    http.Client? client,
    this.probeTimeout = const Duration(milliseconds: 800),
    Future<bool> Function()? portProbe,
  }) : _appPaths =
           appPaths ?? const ['/Applications/WorkBuddy.app'],
       _localApiBase = localApiBase ??
           Uri.parse('http://127.0.0.1:8080'),
       _client = client,
       _portProbe = portProbe;

  final List<String> _appPaths;
  final Uri _localApiBase;
  final http.Client? _client;
  final Future<bool> Function()? _portProbe;

  /// 只探测端口，给了很短的超时——不该拖慢设置页。
  final Duration probeTimeout;

  @override
  CapabilityDescriptor get descriptor => const CapabilityDescriptor(
    id: 'workbuddy',
    displayName: 'WorkBuddy',
    kinds: {
      CapabilityKind.deepResearch,
      CapabilityKind.fileOps,
      CapabilityKind.statusEcho,
    },
    mode: AccessMode.officialApi,
    requiresAccount: true,
    requiresApproval: true,
  );

  @override
  Future<Availability> probe({Duration? timeout}) async {
    final installed = _appPaths.where((path) => Directory(path).existsSync());
    final localApi = await _localApiReady(timeout ?? probeTimeout);

    if (localApi) {
      return Availability.readyNow(
        '本地 HTTP API 可达，可提交任务并接收结果',
        detail: '${_localApiBase.toString()}（需要 serve 模式与 Bearer 凭据）',
      );
    }
    if (installed.isNotEmpty) {
      return Availability.notConfigured(
        '已安装 WorkBuddy 客户端，但本地 API 未开启',
        detail:
            '个人版无开放 API；企业版需在腾讯云开通并在本地开启 serve'
            '${installed.first.split('/').last}',
      );
    }
    return Availability.notConfigured(
      '本机未发现 WorkBuddy 客户端或本地 API',
      detail: '个人版仅支持桌面客户端与 IM 远程下发；企业版需腾讯云席位',
    );
  }

  /// 端口探测：任何 HTTP 响应（含 401/405）都说明服务在，只有连接失败才算不可达。
  Future<bool> _localApiReady(Duration timeout) async {
    final injected = _portProbe;
    if (injected != null) return injected();

    final client = _client ?? http.Client();
    final ownsClient = _client == null;
    try {
      final response = await client
          .get(Uri.parse('${_localApiBase.toString()}/api/v1/jobs'))
          .timeout(timeout);
      return response.statusCode > 0;
    } on TimeoutException {
      return false;
    } on SocketException {
      return false;
    } on Object {
      return false;
    } finally {
      if (ownsClient) client.close();
    }
  }
}
