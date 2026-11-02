/// 互操作契约：把外部软件统一成可探测、可调用、可观测的能力适配器。
///
/// M1 只落地“探测 + 契约定版”：三个适配器只回答“本机能不能用”，
/// 不发起任何真实任务；invoke/progress/awaitResult/cancel 返回“未开放”，
/// 等 M2+ 逐个接实（避免先接一条不稳的路径再返工）。
library;

import '../core/result.dart';

/// 能力种类：只描述“能做什么”，不描述“怎么接”。
enum CapabilityKind {
  chat,
  codeEdit,
  deepResearch,
  fileOps,
  browser,
  statusEcho,
}

/// 接入模式：对应调研里的三类路径。
enum AccessMode {
  /// 对方作为 MCP 客户端/服务端接入（Trae 的 Agent 是 MCP 客户端）。
  mcp,

  /// 官方 HTTP/OpenAPI（ChatGPT Responses、WorkBuddy Managed Agents）。
  officialApi,

  /// 本仓库已有的本地桌面桥（投递 + 状态回显）。
  desktopBridge,

  /// 浏览器/GUI 自动化（默认不启用，ToS 风险）。
  guiAutomation,
}

/// 探测状态：区分“没配好”和“配好了但连不上”，两者处置完全不同。
enum AvailabilityStatus { ready, notConfigured, unreachable, unsupported }

class Availability {
  const Availability(this.status, this.reason, {this.detail = ''});

  final AvailabilityStatus status;
  final String reason;

  /// 可选补充信息（路径、端口、账号要求），设置页原样展示。
  final String detail;

  bool get ready => status == AvailabilityStatus.ready;

  static Availability readyNow(String reason, {String detail = ''}) =>
      Availability(AvailabilityStatus.ready, reason, detail: detail);

  static Availability notConfigured(String reason, {String detail = ''}) =>
      Availability(AvailabilityStatus.notConfigured, reason, detail: detail);

  static Availability unreachable(String reason, {String detail = ''}) =>
      Availability(AvailabilityStatus.unreachable, reason, detail: detail);
}

class CapabilityDescriptor {
  const CapabilityDescriptor({
    required this.id,
    required this.displayName,
    required this.kinds,
    required this.mode,
    this.requiresAccount = false,
    this.requiresApproval = true,
    this.defaultTimeout = const Duration(minutes: 10),
  });

  /// 稳定标识：'trae-cn' / 'chatgpt' / 'workbuddy'。
  final String id;
  final String displayName;
  final Set<CapabilityKind> kinds;
  final AccessMode mode;

  /// 是否需要账号或企业席位才能用。
  final bool requiresAccount;

  /// 默认每次调用都要人确认（M1 的自治级别 L1）。
  final bool requiresApproval;
  final Duration defaultTimeout;
}

class CapabilityRequest {
  const CapabilityRequest({
    required this.goal,
    required this.kind,
    this.payload = const {},
    this.idempotencyKey = '',
  });

  final String goal;
  final CapabilityKind kind;
  final Map<String, Object?> payload;

  /// 失败重试去重；同一 key 的重试不应产生第二次外部副作用。
  final String idempotencyKey;
}

/// 一次调用的句柄：M1 只有占位实现，M2+ 由真实适配器填充。
class CapabilityHandle {
  const CapabilityHandle({required this.id, required this.adapterId, this.externalId = ''});

  final String id;
  final String adapterId;

  /// 对端返回的任务 id（若有）。
  final String externalId;
}

class CapabilityProgress {
  const CapabilityProgress({
    required this.phase,
    required this.summary,
    required this.at,
    this.percent,
  });

  /// queued / running / thinking / tool / done。
  final String phase;
  final String summary;
  final DateTime at;

  /// 对端不给进度就保持 null——不编造百分比。
  final double? percent;
}

class CapabilityResult {
  const CapabilityResult({
    required this.ok,
    required this.summary,
    this.output = const {},
    this.failureReason = '',
  });

  final bool ok;
  final String summary;
  final Map<String, Object?> output;
  final String failureReason;
}

/// 统一能力适配器。实现方负责把对端的原始反馈归一化成下面的类型。
abstract class CapabilityAdapter {
  CapabilityDescriptor get descriptor;

  /// 可用性探测：必须是只读、幂等、有短超时。
  Future<Availability> probe({Duration? timeout});

  /// 提交一次调用；长任务立即返回句柄，不阻塞调用方。
  Future<Result<CapabilityHandle>> invoke(CapabilityRequest request);

  Stream<CapabilityProgress> progress(CapabilityHandle handle);

  Future<Result<CapabilityResult>> awaitResult(
    CapabilityHandle handle, {
    Duration? timeout,
  });

  Future<void> cancel(CapabilityHandle handle);
}

/// M1 共用实现：只探测不执行。子类只需实现 [probe] 与 [descriptor]。
abstract class ProbeOnlyAdapter implements CapabilityAdapter {
  const ProbeOnlyAdapter();

  static const String notOpenCode = 'interop.not-open';
  static const String notOpenReason = 'M1 只做能力探测，任务调用尚未开放';

  @override
  Future<Result<CapabilityHandle>> invoke(CapabilityRequest request) async =>
      const Failure(notOpenCode, notOpenReason);

  @override
  Stream<CapabilityProgress> progress(CapabilityHandle handle) =>
      const Stream<CapabilityProgress>.empty();

  @override
  Future<Result<CapabilityResult>> awaitResult(
    CapabilityHandle handle, {
    Duration? timeout,
  }) async => const Failure(notOpenCode, notOpenReason);

  @override
  Future<void> cancel(CapabilityHandle handle) async {}
}
