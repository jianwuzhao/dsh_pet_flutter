import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_pet_flutter/features/linkage/bridge_hub.dart';

void main() {
  test('桥未注册时不可用，投递超时按 timedOut 失败处理', () async {
    final hub = BridgeHub(ackTimeout: const Duration(milliseconds: 50));
    expect(hub.isAlive('trae-cn'), isFalse);

    final ack = await hub.send('trae-cn', '你好');
    expect(ack.ok, isFalse, reason: '没人轮询/回执，不能伪造成功');
    expect(ack.timedOut, isTrue, reason: '压根没人来取，必须能和「执行失败」区分开');
    expect(hub.snapshot()['pendingAcks'], 0, reason: '超时后要清掉挂起的回执，不能堆积');
  });

  test('轮询取走消息并刷新存活，回执把 Future 置为成功', () async {
    final hub = BridgeHub(ackTimeout: const Duration(seconds: 2));
    final pending = hub.send('trae-cn', '写个排序');

    final drained = hub.drain('trae-cn');
    expect(hub.isAlive('trae-cn'), isTrue);
    expect(drained.single.text, '写个排序');
    expect(hub.drain('trae-cn'), isEmpty, reason: '取过一次就该清空');

    hub.completeAck(drained.single.id, true);
    final ack = await pending;
    expect(ack.ok, isTrue);
    expect(ack.timedOut, isFalse);
  });

  test('回执失败时带原因，且不算超时', () async {
    final hub = BridgeHub(ackTimeout: const Duration(seconds: 2));
    final pending = hub.send('trae-cn', '再来一次');
    final drained = hub.drain('trae-cn');
    hub.completeAck(drained.single.id, false, '命令不存在');
    final ack = await pending;
    expect(ack.ok, isFalse);
    expect(ack.timedOut, isFalse, reason: '扩展来取过，只是执行失败');
    expect(ack.message, '命令不存在');
  });

  test('snapshot 反映存活与积压，供 /bridge/state 诊断', () {
    final hub = BridgeHub(ackTimeout: const Duration(seconds: 2));
    final empty = hub.snapshot();
    expect(empty['adapters'], isEmpty, reason: '还没人轮询过就不该有条目');

    hub.send('trae-cn', '排队中');
    hub.drain('trae-cn');
    final state = hub.snapshot();
    final adapters = state['adapters'] as Map<String, Object?>;
    final trae = adapters['trae-cn'] as Map<String, Object?>;
    expect(trae['alive'], isTrue);
    expect(trae['queued'], 0, reason: '消息已被轮询取走');
    expect(trae['lastPollAgoMs'], isNotNull);
    expect(state['pendingAcks'], 1, reason: '回执还没来');
  });
}
