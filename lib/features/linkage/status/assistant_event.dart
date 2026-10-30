/// 联动统一事件模型与状态聚合。
///
/// 为什么要聚合：桌宠同时接收三种来源（显式推送 / 正文读取 / 前台应用启发式），
/// 三者会打架。这里定一个明确优先级（push > content > watch），并用时间去抖，
/// 保证宠物永远只显示“最可信的那个状态”，不会因为前台切来切去乱跳。
library;

import 'dart:async';

/// 与上游 workStatus 六档一一对应（索引顺序 = workStatus 动画档位）。
enum AssistantStatus { thinking, working, result, waiting, success, error }

AssistantStatus? statusFromName(String? raw) {
  switch (raw) {
    case 'thinking':
      return AssistantStatus.thinking;
    case 'working':
      return AssistantStatus.working;
    case 'result':
      return AssistantStatus.result;
    case 'waiting':
      return AssistantStatus.waiting;
    case 'success':
      return AssistantStatus.success;
    case 'error':
      return AssistantStatus.error;
    default:
      return null;
  }
}

enum EventType {
  status,
  thinking,
  action,
  progress,
  done,
  error,
  notify,
  clear,
}

EventType _typeFromName(String? raw) {
  switch (raw) {
    case 'thinking':
      return EventType.thinking;
    case 'action':
      return EventType.action;
    case 'progress':
      return EventType.progress;
    case 'done':
      return EventType.done;
    case 'error':
      return EventType.error;
    case 'notify':
      return EventType.notify;
    case 'clear':
      return EventType.clear;
    default:
      return EventType.status;
  }
}

class AssistantEvent {
  const AssistantEvent({
    required this.source,
    required this.type,
    this.taskId,
    this.state,
    this.text = '',
    this.delta = false,
    this.current,
    this.total,
  });

  final String source;
  final EventType type;
  final String? taskId;
  final AssistantStatus? state;
  final String text;
  final bool delta;
  final int? current;
  final int? total;

  /// 终态事件要立刻落成动画档位的 success/error。
  bool get isTerminal => type == EventType.done || type == EventType.error;

  factory AssistantEvent.fromJson(Map<String, dynamic> json) {
    final type = _typeFromName(json['type'] as String?);
    final state =
        statusFromName(json['state'] as String?) ??
        switch (type) {
          EventType.thinking => AssistantStatus.thinking,
          EventType.action || EventType.progress => AssistantStatus.working,
          EventType.done => AssistantStatus.success,
          EventType.error => AssistantStatus.error,
          _ => null,
        };
    return AssistantEvent(
      source: json['source'] as String? ?? 'generic',
      type: type,
      taskId: json['taskId'] as String?,
      state: state,
      text: json['text'] as String? ?? '',
      delta: json['delta'] == true,
      current: (json['current'] as num?)?.toInt(),
      total: (json['total'] as num?)?.toInt(),
    );
  }
}

/// 某一来源的最新状态。
class StatusSnapshot {
  const StatusSnapshot({
    required this.state,
    required this.text,
    required this.source,
    required this.updatedAt,
    this.taskId,
  });

  final AssistantStatus state;
  final String text;
  final String source;
  final DateTime updatedAt;
  final String? taskId;

  bool get isTerminal =>
      state == AssistantStatus.success || state == AssistantStatus.error;
}

/// 状态优先级：数字越大越优先。
enum StatusSourceKind { watch, content, push }

int _priority(StatusSourceKind kind) => switch (kind) {
  StatusSourceKind.watch => 1,
  StatusSourceKind.content => 2,
  StatusSourceKind.push => 3,
};

class StatusAggregator {
  StatusAggregator({
    this.debounce = const Duration(seconds: 3),
    this.terminalHold = const Duration(seconds: 8),
  });

  final Duration debounce;
  final Duration terminalHold;

  final Map<StatusSourceKind, StatusSnapshot> _latest = {};
  final Map<StatusSourceKind, Timer> _expiry = {};
  final StreamController<StatusSnapshot?> _changes =
      StreamController.broadcast();

  StatusSnapshot? _current;
  DateTime? _lastSameStateAt;

  Stream<StatusSnapshot?> get changes => _changes.stream;
  StatusSnapshot? get current => _current;

  void update(StatusSourceKind kind, StatusSnapshot snapshot) {
    _latest[kind] = snapshot;
    _expiry[kind]?.cancel();

    // 终态不永久停留：8 秒后自动过期，回落到下一优先级的来源或空闲。
    if (snapshot.isTerminal) {
      _expiry[kind] = Timer(terminalHold, () {
        if (_latest[kind] == snapshot) {
          _latest.remove(kind);
          _resolve();
        }
      });
    } else {
      // 非终态 30 秒无更新视为陈旧，避免切走应用后宠物一直“在忙”。
      _expiry[kind] = Timer(const Duration(seconds: 30), () {
        if (_latest[kind] == snapshot) {
          _latest.remove(kind);
          _resolve();
        }
      });
    }
    _resolve();
  }

  /// 清空某个来源（例如前台切到非关联应用）。
  void clear(StatusSourceKind kind) {
    _expiry[kind]?.cancel();
    _latest.remove(kind);
    _resolve();
  }

  void dispose() {
    for (final timer in _expiry.values) {
      timer.cancel();
    }
    _latest.clear();
    _changes.close();
  }

  void _resolve() {
    StatusSnapshot? winner;
    var winnerPriority = 0;
    for (final entry in _latest.entries) {
      final priority = _priority(entry.key);
      if (priority > winnerPriority) {
        winner = entry.value;
        winnerPriority = priority;
      }
    }

    if (winner == null) {
      if (_current != null) {
        _current = null;
        _lastSameStateAt = null;
        _changes.add(null);
      }
      return;
    }

    final now = DateTime.now();
    if (_current?.state == winner.state && _current?.text == winner.text) {
      // 同状态 3 秒内的重复推送不触发动画重播（工具调用会连发很多条）。
      if (_lastSameStateAt != null &&
          now.difference(_lastSameStateAt!) < debounce) {
        return;
      }
    }
    _current = winner;
    _lastSameStateAt = now;
    _changes.add(winner);
  }
}
