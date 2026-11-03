import 'dart:convert';
import 'dart:io';

import 'package:dsh_pet_flutter/core/result.dart';
import 'package:dsh_pet_flutter/learning/metrics_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// 与 MetricsSnapshot.date 同一口径的 YYYY-MM-DD，保证测试主键与生产一致。
String _dayKey(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

MetricsSnapshot _snapshot(String date, {int sessions = 1}) => MetricsSnapshot(
  date: date,
  sessions: sessions,
  recordedAt: DateTime.parse('${date}T12:00:00'),
);

void main() {
  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('metrics_test');
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  MetricsStore buildStore() => MetricsStore(directory: tmpDir);

  test('首次 record 生成文件，latest 可读回', () {
    final store = buildStore();
    final result = store.record(_snapshot('2026-11-03', sessions: 5));
    expect(result, isA<Success<void>>());
    expect(File('${tmpDir.path}/metrics.json').existsSync(), isTrue);
    expect(store.days(), hasLength(1));
    expect(store.latest()?.sessions, 5);
  });

  test('同日二次 record 是 upsert 不是追加，days 按 date 升序', () {
    final store = buildStore();
    store
      ..record(_snapshot('2026-11-03', sessions: 3))
      ..record(_snapshot('2026-11-02'))
      ..record(_snapshot('2026-11-03', sessions: 7));
    final days = store.days();
    expect(days, hasLength(2));
    expect(days.map((day) => day.date).toList(), ['2026-11-02', '2026-11-03']);
    expect(store.latest()?.sessions, 7);
  });

  test('跨 91 天裁剪只留最近 90 天', () {
    final store = buildStore();
    final base = DateTime(2026, 1, 1);
    for (var offset = 0; offset < 91; offset++) {
      store.record(_snapshot(_dayKey(base.add(Duration(days: offset)))));
    }
    final days = store.days();
    expect(days, hasLength(90));
    // 最旧一天被裁掉，剩余首日是原第二天。
    expect(days.first.date, _dayKey(base.add(const Duration(days: 1))));
    expect(days.last.date, _dayKey(base.add(const Duration(days: 90))));
  });

  test('损坏文件留档并按空库继续，之后仍可写入', () {
    final file = File('${tmpDir.path}/metrics.json');
    file.writeAsStringSync('{not valid json');

    final store = buildStore();
    expect(store.days(), isEmpty);
    expect(store.latest(), isNull);

    final result = store.record(_snapshot('2026-11-03'));
    expect(result, isA<Success<void>>());
    expect(store.latest()?.date, '2026-11-03');
    expect(
      tmpDir
          .listSync()
          .where((entry) => entry.path.contains('.corrupt-'))
          .toList(),
      isNotEmpty,
    );
  });

  test('快照 JSON 往返字段无损，缺字段容错为 0', () {
    final snapshot = MetricsSnapshot(
      date: '2026-11-03',
      sessions: 12,
      memoryActive: 30,
      memoryPending: 4,
      memoryArchived: 2,
      memoryDuplicates: 1,
      feedbackCount: 9,
      policyVersion: 3,
      appearanceRevisions: 5,
      replyAcceptRate7d: 0.75,
      correctionRate7d: 0.25,
      taskSuccessRate7d: 0.6,
      guidelineProposalRate7d: 3,
      pendingBacklog: 8,
      recordedAt: DateTime.parse('2026-11-03T23:59:59'),
    );
    final restored = MetricsSnapshot.fromJson(
      Map<String, dynamic>.from(
        jsonDecode(jsonEncode(snapshot.toJson())) as Map,
      ),
    );
    expect(restored.date, '2026-11-03');
    expect(restored.sessions, 12);
    expect(restored.memoryActive, 30);
    expect(restored.memoryPending, 4);
    expect(restored.memoryArchived, 2);
    expect(restored.memoryDuplicates, 1);
    expect(restored.feedbackCount, 9);
    expect(restored.policyVersion, 3);
    expect(restored.appearanceRevisions, 5);
    expect(restored.replyAcceptRate7d, 0.75);
    expect(restored.correctionRate7d, 0.25);
    expect(restored.taskSuccessRate7d, 0.6);
    // 计数字段可以大于 1，不能被比率夹取截断。
    expect(restored.guidelineProposalRate7d, 3);
    expect(restored.pendingBacklog, 8);
    expect(restored.recordedAt, DateTime.parse('2026-11-03T23:59:59'));

    // 容错解析：只给主键，其余字段一律 0/epoch/-1。
    final sparse = MetricsSnapshot.fromJson({'date': '2026-11-02'});
    expect(sparse.date, '2026-11-02');
    expect(sparse.sessions, 0);
    expect(sparse.memoryActive, 0);
    expect(sparse.memoryPending, 0);
    expect(sparse.memoryArchived, 0);
    expect(sparse.memoryDuplicates, 0);
    expect(sparse.feedbackCount, 0);
    expect(sparse.policyVersion, 0);
    expect(sparse.appearanceRevisions, 0);
    expect(sparse.replyAcceptRate7d, -1);
    expect(sparse.correctionRate7d, -1);
    expect(sparse.taskSuccessRate7d, -1);
    expect(sparse.guidelineProposalRate7d, -1);
    expect(sparse.pendingBacklog, -1);
    expect(sparse.recordedAt, DateTime.fromMillisecondsSinceEpoch(0));
  });

  test('比率字段非法值（负数/NaN/超界）容错：负数归 -1，超界夹取', () {
    final restored = MetricsSnapshot.fromJson({
      'date': '2026-11-03',
      'replyAcceptRate7d': -0.5,
      'correctionRate7d': 1.7,
      'pendingBacklog': double.nan,
    });
    expect(restored.replyAcceptRate7d, -1); // 负数 = 无样本
    expect(restored.correctionRate7d, 1.0); // 超界夹取
    expect(restored.pendingBacklog, -1); // NaN = 未采集
  });
}
