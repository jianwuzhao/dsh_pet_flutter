/// 工具注册表：AI 能力层的“手”，供后续 function-calling 统一口径。
///
/// 薄实现：注册/查找/执行，执行前先过隐私门禁（gate 回调）。
/// 内置两个工具的副作用都通过注入的回调完成——记忆写入接到记忆库
/// （M5 接线），唤起软件接到适配器注册表（M3 接线），本层不持有它们。
library;

import '../core/result.dart';

/// 隐私门禁：capability ∈ screenAwareness/appWatch/memoryRecording/proactiveCare。
typedef PermissionGate = Future<bool> Function(String capability);

class ToolSpec {
  const ToolSpec({
    required this.id,
    required this.name,
    required this.description,
    this.capability = '',
  });

  final String id;
  final String name;
  final String description;

  /// 执行前必须获批的隐私授权；空 = 不涉隐私（纯动作类工具）。
  final String capability;
}

abstract class AssistantTool {
  const AssistantTool();

  ToolSpec get spec;

  Future<Result<String>> execute(Map<String, Object?> args);
}

/// 记忆写入候选：不直接落库，产出待确认提案，用户接受后才生效。
class MemoryProposalTool extends AssistantTool {
  MemoryProposalTool(this.propose);

  /// (content, kind) → 提案描述；M5 由记忆库接线。
  final Future<Result<String>> Function(String content, String kind) propose;

  @override
  ToolSpec get spec => const ToolSpec(
    id: 'memory_propose',
    name: '记忆写入候选',
    description: '把值得长期记住的信息提交为待确认的记忆提案',
    capability: 'memoryRecording',
  );

  @override
  Future<Result<String>> execute(Map<String, Object?> args) async {
    final content = args['content'];
    final kind = args['kind'];
    if (content is! String || content.trim().isEmpty) {
      return const Failure('tool.args', '记忆提案缺少 content');
    }
    return propose(content.trim(), kind is String ? kind : 'fact');
  }
}

/// 唤起关联软件：把提示词送进用户配置的 AI 软件等价动作。
class OpenAppTool extends AssistantTool {
  OpenAppTool(this.launch);

  /// (appId, prompt) → 结果描述；由适配器注册表/调度器接线。
  final Future<Result<String>> Function(String appId, String? prompt) launch;

  @override
  ToolSpec get spec => const ToolSpec(
    id: 'open_app',
    name: '唤起关联软件',
    description: '打开指定关联软件并可选地带上提示词',
  );

  @override
  Future<Result<String>> execute(Map<String, Object?> args) async {
    final appId = args['appId'];
    if (appId is! String || appId.trim().isEmpty) {
      return const Failure('tool.args', '唤起软件缺少 appId');
    }
    final prompt = args['prompt'];
    return launch(appId.trim(), prompt is String ? prompt.trim() : null);
  }
}

class ToolRegistry {
  final Map<String, AssistantTool> _tools = {};

  void register(AssistantTool tool) => _tools[tool.spec.id] = tool;

  List<ToolSpec> get specs => [for (final tool in _tools.values) tool.spec];

  AssistantTool? byId(String id) => _tools[id];

  /// 执行工具：先过隐私门禁，未授权直接拒绝（不静默降级执行）。
  Future<Result<String>> run(
    String toolId,
    Map<String, Object?> args, {
    required PermissionGate gate,
  }) async {
    final tool = _tools[toolId];
    if (tool == null) {
      return Failure('tool.unknown', '未注册的工具：$toolId');
    }
    final capability = tool.spec.capability;
    if (capability.isNotEmpty && !await gate(capability)) {
      return Failure('tool.denied', '「${tool.spec.name}」未获隐私授权，已拒绝执行');
    }
    return tool.execute(args);
  }
}
