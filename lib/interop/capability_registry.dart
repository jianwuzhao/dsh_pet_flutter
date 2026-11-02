/// 能力注册表：统一登记适配器、批量探测、按能力种类查询。
///
/// 探测结果按 TTL 缓存，避免设置页每次重建都打一轮网络/进程检查；
/// 探测全部并行，任一适配器失败不影响其它结果（各自返回结构化状态）。
library;

import 'capability.dart';

class CapabilityRegistry {
  CapabilityRegistry({
    required List<CapabilityAdapter> adapters,
    this.cacheTtl = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : _adapters = List.unmodifiable(adapters),
       _clock = clock ?? DateTime.now;

  final List<CapabilityAdapter> _adapters;
  final Duration cacheTtl;
  final DateTime Function() _clock;

  final Map<String, Availability> _cache = {};
  DateTime? _probedAt;

  List<CapabilityAdapter> get adapters => _adapters;

  CapabilityAdapter? byId(String id) {
    for (final adapter in _adapters) {
      if (adapter.descriptor.id == id) return adapter;
    }
    return null;
  }

  /// 按能力种类筛选（M2 的任务编排用）。
  List<CapabilityAdapter> supporting(CapabilityKind kind) => [
    for (final adapter in _adapters)
      if (adapter.descriptor.kinds.contains(kind)) adapter,
  ];

  /// 上次探测的快照（可能为空，UI 首帧用）。
  Map<String, Availability> get snapshot => Map.unmodifiable(_cache);

  /// 批量探测；[force] = true 时忽略 TTL。
  Future<Map<String, Availability>> probeAll({
    bool force = false,
    Duration? timeout,
  }) async {
    final checkedAt = _probedAt;
    if (!force &&
        checkedAt != null &&
        _cache.isNotEmpty &&
        _clock().difference(checkedAt) < cacheTtl) {
      return snapshot;
    }

    final results = await Future.wait([
      for (final adapter in _adapters) _probeOne(adapter, timeout),
    ]);
    for (final result in results) {
      _cache[result.$1] = result.$2;
    }
    _probedAt = _clock();
    return snapshot;
  }

  /// 单个适配器探测：异常不外抛，统一转成“不可达”。
  Future<(String, Availability)> _probeOne(
    CapabilityAdapter adapter,
    Duration? timeout,
  ) async {
    final id = adapter.descriptor.id;
    try {
      return (id, await adapter.probe(timeout: timeout));
    } on Object catch (error) {
      return (id, Availability.unreachable('探测失败：$error'));
    }
  }
}
