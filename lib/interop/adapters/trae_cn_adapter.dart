/// Trae CN 能力适配器（与联动层的投递适配器同名不同职责，故加 Capability 后缀）。
///
/// 现实接法（见方案 §1.3）：Trae 的 Agent 是 MCP 客户端，
/// 外部程序能稳定利用的是本仓库已有的桌面桥（投递 + 状态回显）；
/// 桥目录存在 = 可投递，否则只能算“已安装但未接线”。
library;

import 'dart:io';

import '../capability.dart';

class TraeCnCapability extends ProbeOnlyAdapter {
  TraeCnCapability({Directory? bridgeDir, List<String>? appPaths})
    : _bridgeDir =
          bridgeDir ??
          Directory('${Platform.environment['HOME'] ?? ''}/.dsh/pet-bridge'),
      _appPaths =
          appPaths ??
          const ['/Applications/Trae CN.app', '/Applications/Trae.app'];

  final Directory _bridgeDir;
  final List<String> _appPaths;

  @override
  CapabilityDescriptor get descriptor => const CapabilityDescriptor(
    id: 'trae-cn',
    displayName: 'Trae CN',
    kinds: {
      CapabilityKind.codeEdit,
      CapabilityKind.fileOps,
      CapabilityKind.statusEcho,
    },
    mode: AccessMode.desktopBridge,
    requiresApproval: true,
  );

  @override
  Future<Availability> probe({Duration? timeout}) async {
    final installed = _appPaths.where((path) => Directory(path).existsSync());
    final bridgeReady = _bridgeReady();

    if (bridgeReady) {
      return Availability.readyNow(
        '桌面桥已启用，可投递任务并接收状态回显',
        detail: '桥目录：${_bridgeDir.path}',
      );
    }
    if (installed.isNotEmpty) {
      return Availability.notConfigured(
        '已安装 ${installed.first.split('/').last}，但桌面桥未启用',
        detail: '桥目录 ${_bridgeDir.path} 不存在或为空（所需扩展可能未运行）',
      );
    }
    return Availability.notConfigured(
      '本机未发现 Trae CN 客户端，也没有桌面桥',
      detail: '可安装客户端，或改为在设置页配置其他能力',
    );
  }

  bool _bridgeReady() {
    if (!_bridgeDir.existsSync()) return false;
    try {
      // 桥目录里只要有文件，就说明扩展跑起来过并留下了状态；
      // 不强制具体文件名，避免因上游命名微调而误判。
      return _bridgeDir.listSync().isNotEmpty;
    } on Object {
      return false;
    }
  }
}
