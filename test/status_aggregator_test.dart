import 'package:dsh_pet_flutter/features/linkage/status/assistant_event.dart';
import 'package:flutter_test/flutter_test.dart';

StatusSnapshot _snapshot(AssistantStatus state, String text) => StatusSnapshot(
  state: state,
  text: text,
  source: 'test',
  updatedAt: DateTime.now(),
);

void main() {
  group('StatusAggregator', () {
    test('push 覆盖 watch，清空后回落到 watch', () {
      final aggregator = StatusAggregator(debounce: Duration.zero);
      addTearDown(aggregator.dispose);

      aggregator.update(
        StatusSourceKind.watch,
        _snapshot(AssistantStatus.waiting, 'app'),
      );
      expect(aggregator.current?.state, AssistantStatus.waiting);

      aggregator.update(
        StatusSourceKind.push,
        _snapshot(AssistantStatus.working, 'busy'),
      );
      expect(aggregator.current?.state, AssistantStatus.working);

      aggregator.clear(StatusSourceKind.push);
      expect(aggregator.current?.state, AssistantStatus.waiting);
    });

    test('三种来源都清空后回到空闲', () async {
      final aggregator = StatusAggregator(debounce: Duration.zero);
      addTearDown(aggregator.dispose);

      final changes = <StatusSnapshot?>[];
      final subscription = aggregator.changes.listen(changes.add);
      addTearDown(subscription.cancel);

      aggregator.update(
        StatusSourceKind.content,
        _snapshot(AssistantStatus.thinking, '读代码'),
      );
      aggregator.clear(StatusSourceKind.content);
      await Future<void>.delayed(Duration.zero);

      expect(aggregator.current, isNull);
      expect(changes.last, isNull);
    });

    test('同状态同文案 3 秒内不重复通知', () async {
      final aggregator = StatusAggregator();
      addTearDown(aggregator.dispose);

      var notifications = 0;
      final subscription = aggregator.changes.listen((_) => notifications++);
      addTearDown(subscription.cancel);

      aggregator.update(
        StatusSourceKind.push,
        _snapshot(AssistantStatus.working, '写代码'),
      );
      aggregator.update(
        StatusSourceKind.push,
        _snapshot(AssistantStatus.working, '写代码'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(notifications, 1);
    });

    test('终态保持一段时间后自动过期', () async {
      final aggregator = StatusAggregator(
        debounce: Duration.zero,
        terminalHold: const Duration(milliseconds: 40),
      );
      addTearDown(aggregator.dispose);

      aggregator.update(
        StatusSourceKind.push,
        _snapshot(AssistantStatus.success, '完成'),
      );
      expect(aggregator.current?.state, AssistantStatus.success);

      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(aggregator.current, isNull);
    });

    test('事件把 thinking 映射为 thinking 状态', () {
      final event = AssistantEvent.fromJson({
        'source': 'trae-cn',
        'type': 'thinking',
        'text': '…',
      });
      expect(event.state, AssistantStatus.thinking);
      expect(event.delta, isFalse);
    });

    test('done / error 事件映射终态', () {
      final done = AssistantEvent.fromJson({
        'source': 'trae-cn',
        'type': 'done',
        'text': 'ok',
      });
      final error = AssistantEvent.fromJson({
        'source': 'trae-cn',
        'type': 'error',
        'text': 'boom',
      });
      expect(done.state, AssistantStatus.success);
      expect(done.isTerminal, isTrue);
      expect(error.state, AssistantStatus.error);
      expect(error.isTerminal, isTrue);
    });
  });
}
