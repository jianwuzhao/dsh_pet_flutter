/// 自主运行的状态回显契约：沿用 `/event` 信封，新增 `run.progress` 事件族。
///
/// 设计目标是“不刷屏”：同一 runId 同一 phase 至少间隔 5s 才允许再上报；
/// 阶段变更与结局（done/failed/cancelled/wait_approval）必发；
/// 单次运行最多 40 条进度事件，超出后只保留阶段变更。
library;

/// 运行阶段：覆盖从计划到结局的全过程。
enum RunPhase {
  plan,
  act,
  observe,
  waitApproval,
  done,
  failed,
  cancelled,
}

RunPhase? runPhaseFromName(String? raw) => switch (raw) {
  'plan' => RunPhase.plan,
  'act' => RunPhase.act,
  'observe' => RunPhase.observe,
  'wait_approval' => RunPhase.waitApproval,
  'done' => RunPhase.done,
  'failed' => RunPhase.failed,
  'cancelled' => RunPhase.cancelled,
  _ => null,
};

String runPhaseName(RunPhase phase) => switch (phase) {
  RunPhase.plan => 'plan',
  RunPhase.act => 'act',
  RunPhase.observe => 'observe',
  RunPhase.waitApproval => 'wait_approval',
  RunPhase.done => 'done',
  RunPhase.failed => 'failed',
  RunPhase.cancelled => 'cancelled',
};

/// 结局类阶段：必发、不受节流限制。
bool isRunTerminal(RunPhase phase) =>
    phase == RunPhase.done ||
    phase == RunPhase.failed ||
    phase == RunPhase.cancelled ||
    phase == RunPhase.waitApproval;

class RunEvent {
  const RunEvent({
    required this.runId,
    required this.phase,
    required this.summary,
    required this.at,
    this.step,
    this.totalSteps,
    this.source = 'dafishu',
  });

  final String runId;
  final RunPhase phase;
  final String summary;
  final DateTime at;

  /// 当前步（从 1 开始）；计划未定稿时可空。
  final int? step;

  /// 总步数；计划未定稿时为空——不编造假总数。
  final int? totalSteps;

  /// 事件来源，沿用 /event 的 source 语义。
  final String source;

  /// 序列化成 `/event` 的信封：保留既有字段，新增 run 字段。
  Map<String, dynamic> toJson() => {
    'source': source,
    'type': 'run.progress',
    'state': switch (phase) {
      RunPhase.done => 'success',
      RunPhase.failed || RunPhase.cancelled => 'error',
      RunPhase.waitApproval => 'waiting',
      _ => 'running',
    },
    'text': summary,
    'runId': runId,
    'phase': runPhaseName(phase),
    if (step != null) 'step': step,
    if (totalSteps != null) 'totalSteps': totalSteps,
    'ts': at.toIso8601String(),
  };

  /// 从 `/event` 请求体解析；字段不全或阶段非法返回 null（由服务端给 400）。
  static RunEvent? fromJson(Map<String, dynamic> json) {
    final runId = (json['runId'] as String?)?.trim() ?? '';
    if (runId.isEmpty) return null;
    final phase = runPhaseFromName(json['phase'] as String?);
    if (phase == null) return null;
    final at =
        DateTime.tryParse(json['ts'] as String? ?? '') ?? DateTime.now();
    return RunEvent(
      runId: runId,
      phase: phase,
      summary: (json['text'] as String? ?? json['summary'] as String? ?? '')
          .trim(),
      at: at,
      step: (json['step'] as num?)?.toInt(),
      totalSteps: (json['totalSteps'] as num?)?.toInt(),
      source: (json['source'] as String?)?.trim().isNotEmpty == true
          ? (json['source'] as String).trim()
          : 'dafishu',
    );
  }
}

/// 是否接受这条事件：结局必发；其余按“同 phase 5s 内只留一条 + 总条数 40”限流。
class RunEventThrottle {
  RunEventThrottle({
    this.minInterval = const Duration(seconds: 5),
    this.maxEventsPerRun = 40,
  });

  final Duration minInterval;
  final int maxEventsPerRun;

  final Map<String, ({RunPhase phase, DateTime at, int count})> _state = {};

  /// 返回 true 表示应发出；false 表示被节流丢弃。
  bool accept(RunEvent event) {
    final last = _state[event.runId];
    final count = (last?.count ?? 0);

    if (isRunTerminal(event.phase)) {
      _state[event.runId] = (phase: event.phase, at: event.at, count: count + 1);
      return true;
    }

    // 非结局阶段的硬上限：超出后只允许阶段变更，防止长任务刷屏。
    if (count >= maxEventsPerRun) {
      final changed = last == null || last.phase != event.phase;
      if (!changed) return false;
      _state[event.runId] = (phase: event.phase, at: event.at, count: count + 1);
      return true;
    }

    if (last != null &&
        last.phase == event.phase &&
        event.at.difference(last.at) < minInterval) {
      return false;
    }

    _state[event.runId] = (phase: event.phase, at: event.at, count: count + 1);
    return true;
  }

  /// 运行结束（终态已发出）后清理计数，避免长期运行累积内存。
  void forget(String runId) => _state.remove(runId);
}
