/// Trae 扩展桥接：扩展在 Trae 进程里轮询待发消息，宠物这边只管排队与等回执。
///
/// 为什么走"扩展 + HTTP 轮询"而不是继续剪贴板注入：扩展能直接执行
/// workbench.action.chat.open 把话送进对话，完全不需要"辅助功能"授权；
/// 回环 + token 与事件服务同一套鉴权。
library;

import 'dart:async';

class BridgePrompt {
  const BridgePrompt({required this.id, required this.text});

  final int id;
  final String text;

  Map<String, Object> toJson() => {'id': id, 'text': text};
}

/// 扩展对一条消息的回执。
///
/// timedOut 区分「压根没人来取」和「取了但执行失败」——
/// 前者说明桥已断（提示用户重启 Trae），后者把扩展的报错原样透传给用户。
class BridgeAck {
  const BridgeAck({required this.ok, this.timedOut = false, this.message = ''});

  final bool ok;
  final bool timedOut;
  final String message;
}

class BridgeHub {
  BridgeHub({this.ackTimeout = const Duration(seconds: 8)});

  /// 扩展确认收到前最多等多久；超时按失败处理（不伪造成功）。
  final Duration ackTimeout;

  /// 扩展每 800ms 轮询一次，最近 5 秒内来过才算桥在线。
  /// 窗口必须大于 ackTimeout：isAlive 为真时，正在轮询的扩展一定来得及取走并回执。
  static const Duration aliveWindow = Duration(seconds: 5);

  final Map<String, List<BridgePrompt>> _queues = {};
  final Map<int, Completer<BridgeAck>> _pendingAcks = {};
  final Map<String, DateTime> _lastPollAt = {};
  int _nextId = 1;

  /// 桥在最近的轮询窗口内活着才算可用，否则投递回退到剪贴板路线。
  bool isAlive(String adapterId) {
    final last = _lastPollAt[adapterId];
    return last != null && DateTime.now().difference(last) < aliveWindow;
  }

  /// 入队并等扩展回执。
  Future<BridgeAck> send(String adapterId, String text) {
    final id = _nextId++;
    _queues
        .putIfAbsent(adapterId, () => [])
        .add(BridgePrompt(id: id, text: text));
    final completer = Completer<BridgeAck>();
    _pendingAcks[id] = completer;
    return completer.future.timeout(
      ackTimeout,
      onTimeout: () {
        // 永远不来的回执不能留在表里堆积。
        _pendingAcks.remove(id);
        return BridgeAck(
          ok: false,
          timedOut: true,
          message: '桥接插件 ${ackTimeout.inSeconds} 秒内没有确认',
        );
      },
    );
  }

  /// 扩展轮询：取走该适配器的全部待发消息，并刷新存活时间戳。
  List<BridgePrompt> drain(String adapterId) {
    _lastPollAt[adapterId] = DateTime.now();
    final queue = _queues[adapterId];
    if (queue == null || queue.isEmpty) return const [];
    _queues[adapterId] = [];
    return queue;
  }

  /// 扩展回执；message 携带失败原因，会原样透传到宠物气泡。
  void completeAck(int id, bool ok, [String message = '']) {
    final completer = _pendingAcks.remove(id);
    if (completer == null || completer.isCompleted) return;
    completer.complete(BridgeAck(ok: ok, message: message));
  }

  /// 诊断快照：回答「扩展到底有没有在轮询」，/bridge/state 直接返回它。
  Map<String, Object?> snapshot() {
    final now = DateTime.now();
    final ids = {..._lastPollAt.keys, ..._queues.keys};
    return {
      'adapters': {
        for (final id in ids)
          id: {
            'alive': isAlive(id),
            'lastPollAgoMs': _lastPollAt[id] == null
                ? null
                : now.difference(_lastPollAt[id]!).inMilliseconds,
            'queued': _queues[id]?.length ?? 0,
          },
      },
      'pendingAcks': _pendingAcks.length,
    };
  }
}
