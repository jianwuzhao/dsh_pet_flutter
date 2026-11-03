import 'dart:io';

import 'package:dsh_pet_flutter/core/result.dart';
import 'package:dsh_pet_flutter/learning/eval_gate.dart';
import 'package:dsh_pet_flutter/learning/feedback_collector.dart';
import 'package:dsh_pet_flutter/learning/learning_loop.dart';
import 'package:dsh_pet_flutter/learning/policy_store.dart';
import 'package:dsh_pet_flutter/persona/expression/expression_layer.dart';
import 'package:dsh_pet_flutter/persona/memory/memory_entry.dart';
import 'package:dsh_pet_flutter/persona/memory/memory_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录气泡的宿主，用于断言自动回滚的告知。
class _FakeHost extends ExpressionHost {
  final List<String> bubbles = [];

  @override
  void playAnimation(String name) {}

  @override
  void showBubble(
    String text, {
    String? meme,
    bool dismissible = false,
    void Function()? onTap,
  }) => bubbles.add(text);
}

void main() {
  late Directory tmpDir;
  late MemoryStore memory;
  var now = DateTime(2026, 1, 1, 12);

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('learning_test');
    memory = MemoryStore(directory: Directory('${tmpDir.path}/memory'));
    now = DateTime(2026, 1, 1, 12);
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  FeedbackCollector buildCollector() => FeedbackCollector(
    file: File('${tmpDir.path}/feedback.jsonl'),
    clock: () => now,
  );

  PolicyStore buildPolicy() => PolicyStore(
    directory: Directory('${tmpDir.path}/learning'),
    clock: () => now,
  );

  LearningLoop buildLoop(
    FeedbackCollector collector,
    PolicyStore policy, {
    _FakeHost? host,
  }) => LearningLoop(
    collector: collector,
    policy: policy,
    host: host ?? _FakeHost(),
    clock: () => now,
  );

  group('FeedbackCollector', () {
    test('三种语义都落盘，坏行跳过', () {
      final collector = buildCollector();
      collector
        ..record(FeedbackVerdict.accepted, target: 'memory:m1')
        ..record(FeedbackVerdict.rejected, target: 'reply:r1')
        ..record(
          FeedbackVerdict.corrected,
          target: 'policy:replyLength',
          detail: '太长了',
        );

      final events = collector.load();
      expect(events.length, 3);
      expect(events[0].verdict, FeedbackVerdict.accepted);
      expect(events[1].target, startsWith('reply:'));
      expect(events[2].detail, '太长了');

      File('${tmpDir.path}/feedback.jsonl').writeAsStringSync(
        '{bad json}\n${File('${tmpDir.path}/feedback.jsonl').readAsStringSync()}',
      );
      expect(collector.load().length, 3);
    });

    test('count 按窗口与前缀过滤；非 24h 内样本不计', () {
      final collector = buildCollector();
      now = DateTime(2026, 1, 1, 12);
      collector.record(FeedbackVerdict.corrected, target: 'policy:replyLength');
      now = DateTime(2026, 1, 3, 12); // 48 小时后
      expect(
        collector.count(
          FeedbackVerdict.corrected,
          target: 'policy:replyLength',
          now: now,
        ),
        0,
      );
      collector.record(
        FeedbackVerdict.corrected,
        target: 'policy:replyLength',
      );
      expect(
        collector.count(
          FeedbackVerdict.corrected,
          target: 'policy',
          now: now,
        ),
        1,
      );
    });
  });

  group('PolicyStore 版本治理', () {
    test('默认参数与首版历史；apply 生成新版本与快照文件', () {
      final store = buildPolicy();
      expect(store.version, 0);
      expect(store.params.replyLength, 'balanced');
      expect(store.history.length, 1);

      final next = store.params.copyWith(replyLength: 'brief');
      expect(store.apply(next, note: '用户嫌长'), isA<Success<void>>());
      expect(store.version, 1);
      expect(store.params.replyLength, 'brief');
      expect(
        File('${tmpDir.path}/learning/snapshots/policy.v1.json').existsSync(),
        isTrue,
      );

      final reopened = buildPolicy();
      expect(reopened.version, 1);
      expect(reopened.params.replyLength, 'brief');
    });

    test('回滚回到上一版，且回滚本身也进历史（可追溯）', () {
      final store = buildPolicy();
      store.apply(store.params.copyWith(replyLength: 'brief'));
      store.apply(store.params.copyWith(replyLength: 'detailed'));
      expect(store.version, 2);

      expect(store.rollback(), isA<Success<void>>());
      expect(store.params.replyLength, 'brief');
      expect(store.version, 3);
      expect(store.history.last.note, contains('回滚到 v1'));
    });

    test('只有初始版时回滚失败', () {
      final store = buildPolicy();
      expect((store.rollback() as Failure<void>).code, 'policy.no-previous');
    });

    test('rollbackTo 指定版本；不存在的版本结构化失败', () {
      final store = buildPolicy();
      store.apply(store.params.copyWith(replyLength: 'brief'));
      store.apply(store.params.copyWith(replyLength: 'detailed'));

      expect(store.rollbackTo(0), isA<Success<void>>());
      expect(store.params.replyLength, 'balanced');
      expect((store.rollbackTo(99) as Failure<void>).code, 'policy.not-found');
    });

    test('参数白名单与保护字段：非法字段/值不能写入', () {
      const params = PolicyParams();
      expect(params.withField('identity', 'x'), isNull);
      expect(params.withField('replyLength', 'huge'), isNull);
      expect(params.withField('careTone', 'quiet')?.careTone, 'quiet');
      expect(protectedFields, contains('bottomLines'));
      expect(learnableFields, isNot(contains('values')));
    });
  });

  group('EvalGate 门禁', () {
    const gate = EvalGate();

    test('同向样本不足 3 条不通过', () {
      final result = gate.reviewPolicyChange(
        field: 'replyLength',
        value: 'brief',
        supporting: 2,
      );
      expect(result.approved, isFalse);
      expect(result.reason, contains('样本不足'));
    });

    test('样本充足且反向不占优时通过', () {
      final result = gate.reviewPolicyChange(
        field: 'replyLength',
        value: 'brief',
        supporting: 3,
        opposing: 1,
      );
      expect(result.approved, isTrue);
    });

    test('反向样本不低于同向时拒绝', () {
      final result = gate.reviewPolicyChange(
        field: 'replyLength',
        value: 'brief',
        supporting: 3,
        opposing: 3,
      );
      expect(result.approved, isFalse);
    });

    test('安全边界字段一律拒绝（人格底线不可自动改）', () {
      for (final field in protectedFields) {
        final result = gate.reviewPolicyChange(
          field: field,
          value: 'anything',
          supporting: 99,
        );
        expect(result.approved, isFalse, reason: '$field 不该放行');
        expect(result.reason, contains('安全边界'));
      }
    });

    test('三级/四级学习未开放', () {
      expect(gate.reviewLearningLevel(2).approved, isTrue);
      final level3 = gate.reviewLearningLevel(3);
      expect(level3.approved, isFalse);
      expect(level3.reason, contains('尚未开放'));
      expect(gate.reviewLearningLevel(4).approved, isFalse);
    });
  });

  group('LearningLoop 记忆提案闭环', () {
    test('接受 → 生效并记正样本；拒绝 → 丢弃并记负样本', () {
      final collector = buildCollector();
      final loop = buildLoop(collector, buildPolicy());

      memory.add(MemoryEntry(
        id: 'm1',
        kind: MemoryKind.preference,
        content: '称呼偏好：老板',
        createdAt: now,
        status: MemoryStatus.pending,
      ));
      expect(loop.acceptMemoryProposal(memory, 'm1'), isA<Success<void>>());
      expect(memory.pending, isEmpty);
      expect(memory.entries(status: MemoryStatus.active).length, 1);

      memory.add(MemoryEntry(
        id: 'm2',
        kind: MemoryKind.fact,
        content: '在写 Flutter',
        createdAt: now,
        status: MemoryStatus.pending,
      ));
      expect(loop.rejectMemoryProposal(memory, 'm2'), isA<Success<void>>());
      expect(memory.entries(status: MemoryStatus.pending), isEmpty);

      final events = collector.load();
      expect(events.length, 2);
      expect(events[0].verdict, FeedbackVerdict.accepted);
      expect(events[1].verdict, FeedbackVerdict.rejected);
    });

    test('拒绝时附纠正 → 记 corrected 且正文留档', () {
      final collector = buildCollector();
      final loop = buildLoop(collector, buildPolicy());

      memory.add(MemoryEntry(
        id: 'm1',
        kind: MemoryKind.fact,
        content: 'x',
        createdAt: now,
        status: MemoryStatus.pending,
      ));
      loop.rejectMemoryProposal(memory, 'm1', correction: '太长了');

      final event = collector.load().single;
      expect(event.verdict, FeedbackVerdict.corrected);
      expect(event.detail, '太长了');
      expect(event.target, 'policy:replyLength');
    });
  });

  group('LearningLoop 策略提案闭环', () {
    test('连续 3 次“太长”才越过门禁生成提案；接受后版本 +1', () {
      final collector = buildCollector();
      final policy = buildPolicy();
      final loop = buildLoop(collector, policy);

      loop
        ..rejectReply(correction: '太长了')
        ..rejectReply(correction: '还是太长');
      expect(policy.proposals, isEmpty);

      loop.rejectReply(correction: '太长了');
      expect(policy.proposals.length, 1);
      final proposal = policy.proposals.single;
      expect(proposal.field, 'replyLength');
      expect(proposal.value, 'brief');

      expect(loop.acceptPolicyProposal(proposal.id), isA<Success<void>>());
      expect(policy.version, 1);
      expect(policy.params.replyLength, 'brief');
      expect(policy.proposals, isEmpty);
    });

    test('拒绝策略提案：丢弃并记负样本，参数不变', () {
      final collector = buildCollector();
      final policy = buildPolicy();
      final loop = buildLoop(collector, policy);

      for (var i = 0; i < 3; i++) {
        loop.rejectReply(correction: '别用表格');
      }
      final proposal = policy.proposals.single;
      expect(proposal.field, 'tablePreference');

      expect(loop.rejectPolicyProposal(proposal.id), isA<Success<void>>());
      expect(policy.proposals, isEmpty);
      expect(policy.params.tablePreference, 'allow');
      expect(
        collector.load().last.verdict,
        FeedbackVerdict.rejected,
      );
    });

    test('纠正解析覆盖各字段，模糊表述不产出候选', () {
      expect(LearningLoop.parseCorrection('太长了'), ('replyLength', 'brief'));
      expect(LearningLoop.parseCorrection('详细一点'), ('replyLength', 'detailed'));
      expect(LearningLoop.parseCorrection('别用 emoji'), isNull);
      expect(LearningLoop.parseCorrection('别用emoji'), ('emojiUsage', 'none'));
      expect(LearningLoop.parseCorrection('别用表格'), ('tablePreference', 'avoid'));
      expect(LearningLoop.parseCorrection('用表格'), ('tablePreference', 'allow'));
      expect(LearningLoop.parseCorrection('少关心我'), ('careTone', 'quiet'));
      expect(LearningLoop.parseCorrection('嗯嗯'), isNull);
    });
  });

  group('自动回滚', () {
    test('新版本 24h 内累计 2 次拒绝 → 回滚并气泡告知', () {
      final collector = buildCollector();
      final policy = buildPolicy();
      final host = _FakeHost();
      final loop = buildLoop(collector, policy, host: host);

      // v1 先应用“详细”版本，再学习到“简短”，回滚应回到“详细”。
      policy.apply(policy.params.copyWith(replyLength: 'detailed'), note: '灰度');
      for (var i = 0; i < 3; i++) {
        loop.rejectReply(correction: '太长了');
      }
      expect(policy.proposals, isNotEmpty);
      loop.acceptPolicyProposal(policy.proposals.single.id);
      expect(policy.version, 2);
      expect(policy.params.replyLength, 'brief');

      // 应用后过一会儿再被拒绝，才算窗口内的新样本；第二次拒绝触发自动回滚。
      now = now.add(const Duration(minutes: 10));
      loop.rejectReply();
      loop.rejectReply();
      expect(policy.params.replyLength, 'detailed');
      expect(host.bubbles.last, contains('回滚'));
      // 已回滚过：再检查一次不会重复回滚。
      expect(loop.checkAutoRollback(), isFalse);
    });

    test('超过 24h 窗口不再自动回滚', () {
      final collector = buildCollector();
      final policy = buildPolicy();
      final loop = buildLoop(collector, policy);

      policy.apply(policy.params.copyWith(replyLength: 'brief'));
      now = now.add(const Duration(hours: 25));
      loop
        ..rejectReply()
        ..rejectReply();

      expect(loop.checkAutoRollback(), isFalse);
    });

    test('只有初始版本时不自动回滚', () {
      final collector = buildCollector();
      final policy = buildPolicy();
      final loop = buildLoop(collector, policy);
      loop
        ..rejectReply()
        ..rejectReply();
      expect(policy.version, 0);
      expect(loop.checkAutoRollback(), isFalse);
    });
  });
}
