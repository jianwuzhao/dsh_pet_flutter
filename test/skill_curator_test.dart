import 'dart:convert';
import 'dart:io';

import 'package:dsh_pet_flutter/ai/skill_library.dart';
import 'package:dsh_pet_flutter/learning/skill_curator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  var now = DateTime(2026, 11, 3, 10);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('skill_curator_test');
    now = DateTime(2026, 11, 3, 10);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  SkillCurator build({int maxSkills = SkillLibrary.maxSkills}) {
    final library = SkillLibrary(directory: tmp, clock: () => now)..load();
    return SkillCurator(
      library: library,
      eventsFile: File('${tmp.path}/skill_events.jsonl'),
      maxSkills: maxSkills,
      clock: () => now,
    );
  }

  SkillManifest draft({
    String name = 'suggest-report-outline',
    String description = '生成周报大纲时先问清汇报对象与篇幅',
    String triggers = '周报|report|outline',
    String body = '1. 先确认汇报对象与期望篇幅再动笔\n2. 大纲默认四段：进展/风险/数据/下步',
    List<String> evidence = const ['r-1024'],
  }) => SkillManifest(
    name: name,
    description: description,
    triggers: triggers,
    body: body,
    createdAt: now,
    originReflectionIds: evidence,
  );

  test('无证据链的草案直接丢弃', () {
    final curator = build();
    final result = curator.propose(draft(evidence: const []));
    expect(result.isSuccess, isFalse, reason: '不可回溯的草案必须挡下');
    expect(curator.pending, isEmpty);
  });

  test('提案入待确认队列并写审计事件', () {
    final curator = build();
    final result = curator.propose(draft());
    expect(result.isSuccess, isTrue);
    expect(curator.pending, hasLength(1));

    final events = File('${tmp.path}/skill_events.jsonl').readAsLinesSync();
    expect(events, hasLength(1));
    expect(jsonDecode(events.single)['type'], 'proposed');
  });

  test('相似内容去重：换个说法也不重复入队', () {
    final curator = build();
    curator.propose(draft());
    // 同内容不同 name：bigram 相似度仍高，拒绝入队。
    final duplicate = curator.propose(
      draft(name: 'weekly-report-ask-first'),
    );
    expect(duplicate.isSuccess, isFalse);
    expect(duplicate.failureOrNull!.code, 'skill.duplicate');
    expect(curator.pending, hasLength(1), reason: '重复草案不应入队');
    // 不同领域的技能正常入队。
    curator.propose(
      draft(
        name: 'avoid-table-replies',
        description: '简短问题不要用表格回复',
        triggers: '表格|table',
        body: '1. 先判断问题复杂度\n2. 简短问题直接用两三句话回答',
      ),
    );
    expect(curator.pending, hasLength(2));
  });

  test('每日提案预算：第 4 条被拒，跨天恢复', () {
    final curator = build();
    for (var index = 0; index < 3; index++) {
      curator.propose(
        draft(
          name: 'skill-$index',
          description: '做法 $index：完全不同的经验内容编号$index',
          triggers: '词$index',
          body: '第 $index 种做法：步骤甲$index、步骤乙$index、步骤丙$index',
        ),
      );
    }
    expect(curator.pending, hasLength(3));
    final fourth = curator.propose(
      draft(
        name: 'skill-3',
        description: '做法 3：完全不同的经验内容编号3',
        triggers: '词3',
        body: '第 3 种做法：步骤甲3、步骤乙3、步骤丙3',
      ),
    );
    expect(fourth.isSuccess, isFalse);
    expect(fourth.failureOrNull!.code, 'skill.budget');

    now = now.add(const Duration(days: 1));
    final nextDay = curator.propose(
      draft(
        name: 'skill-3',
        description: '做法 3：完全不同的经验内容编号3',
        triggers: '词3',
        body: '第 3 种做法：步骤甲3、步骤乙3、步骤丙3',
      ),
    );
    expect(nextDay.isSuccess, isTrue, reason: '预算按自然日重置');
  });

  test('库存上限一进一出：满库必须先退役', () {
    final curator = build(maxSkills: 2);
    curator.propose(draft());
    curator.propose(
      draft(
        name: 'avoid-table-replies',
        description: '简短问题不要用表格回复',
        triggers: '表格|table',
        body: '1. 先判断问题复杂度\n2. 简短问题直接用两三句话回答',
      ),
    );
    final third = curator.propose(
      draft(
        name: 'ask-before-delete',
        description: '删除文件前先向用户确认范围',
        triggers: '删除|delete',
        body: '1. 列出将被删除的文件清单\n2. 等用户确认范围后再执行',
      ),
    );
    expect(third.isSuccess, isFalse);
    expect(third.failureOrNull!.code, 'skill.limit');

    curator.accept('suggest-report-outline');
    curator.retire('suggest-report-outline');
    final afterRetire = curator.propose(
      draft(
        name: 'ask-before-delete',
        description: '删除文件前先向用户确认范围',
        triggers: '删除|delete',
        body: '1. 列出将被删除的文件清单\n2. 等用户确认范围后再执行',
      ),
    );
    expect(afterRetire.isSuccess, isTrue, reason: '退役释放库存后可再新增');
  });

  test('拒绝后 24h 冷却，且重启后从审计流恢复', () {
    final curator = build();
    curator.propose(draft());
    curator.reject('suggest-report-outline');

    final rejected = curator.propose(draft());
    expect(rejected.isSuccess, isFalse);
    expect(rejected.failureOrNull!.code, 'skill.cooldown');

    // 新实例（模拟重启）：冷却仍生效，来源是审计流。
    final reopened = build();
    final stillCooling = reopened.propose(draft());
    expect(stillCooling.isSuccess, isFalse);
    expect(stillCooling.failureOrNull!.code, 'skill.cooldown');

    now = now.add(const Duration(hours: 25));
    final afterCooldown = reopened.propose(draft());
    expect(afterCooldown.isSuccess, isTrue, reason: '冷却过期后允许重新提案');
  });

  test('accept/reject/retire/reactivate 状态流转与事件留痕', () {
    final curator = build();
    curator.propose(draft());

    // reject 只作用于 pending。
    expect(curator.retire('suggest-report-outline').isSuccess, isFalse);

    curator.accept('suggest-report-outline');
    expect(curator.active, hasLength(1));
    // accept 只作用于 pending：重复 accept 失败。
    expect(curator.accept('suggest-report-outline').isSuccess, isFalse);

    curator.retire('suggest-report-outline', reason: '同域纠正率未降');
    expect(curator.active, isEmpty);

    curator.reactivate('suggest-report-outline');
    expect(curator.active, hasLength(1));

    final events = File('${tmp.path}/skill_events.jsonl')
        .readAsLinesSync()
        .map((line) => jsonDecode(line) as Map)
        .toList();
    expect(events.map((event) => event['type']).toList(), [
      'proposed',
      'accepted',
      'retired',
      'reactivated',
    ]);
  });
}
