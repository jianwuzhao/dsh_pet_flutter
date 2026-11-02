/// 任务规划：接口 + 委托 LLM 的实现。
///
/// 首期不入主流程（会话直接问答），保留给后续“多步任务”接线；
/// 接口先行是为了让会话服务不依赖具体实现。
library;

import '../core/result.dart';
import 'llm_provider.dart';

class TaskPlan {
  const TaskPlan({required this.goal, required this.steps});

  final String goal;
  final List<String> steps;
}

abstract class TaskPlanner {
  Future<Result<TaskPlan>> plan(String goal);
}

/// 委托实现：让 LLM 把目标拆成编号步骤，再按行解析。
class LlmTaskPlanner implements TaskPlanner {
  LlmTaskPlanner(this.provider);

  final LlmProvider provider;

  @override
  Future<Result<TaskPlan>> plan(String goal) async {
    final trimmed = goal.trim();
    if (trimmed.isEmpty) {
      return const Failure('planner.empty', '规划目标为空');
    }
    final reply = await provider.chat(
      LlmRequest(
        system: '把用户目标拆成 1~5 个可执行步骤，每行一步，'
            '形如“1. 做什么”。不要解释、不要寒暄、不要总结。',
        messages: [LlmMessage.user(trimmed)],
      ),
    );
    final content = reply.valueOrNull?.content;
    if (content == null) {
      final failure = reply.failureOrNull!;
      return Failure(failure.code, failure.reason);
    }

    final steps = [
      for (final line in content.split('\n'))
        if (_stripIndex(line.trim()).isNotEmpty) _stripIndex(line.trim()),
    ];
    if (steps.isEmpty) {
      return const Failure('planner.parse', '规划结果解析失败：没有可用步骤');
    }
    return Success(TaskPlan(goal: trimmed, steps: steps));
  }

  /// 去掉行首的 “1. / 1、/ - ” 之类序号，只留步骤本身。
  String _stripIndex(String line) =>
      line.replaceFirst(RegExp(r'^\s*(\d+[.、)]|[-*•])\s*'), '');
}
