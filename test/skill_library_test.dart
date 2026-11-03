import 'dart:convert';
import 'dart:io';

import 'package:dsh_pet_flutter/ai/skill_library.dart';
import 'package:dsh_pet_flutter/core/result.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late DateTime now;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('skill_library_test');
    now = DateTime(2026, 11, 3, 10);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  SkillManifest draft({
    String name = 'suggest-report-outline',
    String description = '生成周报大纲时先问清汇报对象与篇幅',
    String triggers = '周报|report|outline',
    String body = '1. 先确认汇报对象与期望篇幅再动笔\n2. 大纲默认四段：进展/风险/数据/下步',
  }) => SkillManifest(
    name: name,
    description: description,
    triggers: triggers,
    body: body,
    createdAt: now,
    originReflectionIds: const ['r-1024', 'r-1101'],
  );

  test('空目录装载为空库，不抛异常', () {
    final library = SkillLibrary(directory: tmp, clock: () => now);
    library.load();
    expect(library.all, isEmpty);
  });

  test('保存新技能落盘 SKILL.md 与索引，重开恢复', () {
    final library = SkillLibrary(directory: tmp, clock: () => now);
    library.load();
    final saved = library.save(draft());
    expect(saved, isA<Success<SkillManifest>>());
    expect(
      File('${tmp.path}/suggest-report-outline/SKILL.md').existsSync(),
      isTrue,
    );

    final reopened = SkillLibrary(directory: tmp, clock: () => now)..load();
    final restored = reopened.byName('suggest-report-outline');
    expect(restored, isNotNull);
    expect(restored!.status, SkillStatus.pending);
    expect(restored.version, 1);
    expect(restored.originReflectionIds, ['r-1024', 'r-1101']);
    expect(restored.body, contains('先确认汇报对象'));
  });

  test('非法名称与缺失字段被拒绝', () {
    final library = SkillLibrary(directory: tmp, clock: () => now)..load();
    expect(
      library.save(draft(name: 'Bad Name')).isSuccess,
      isFalse,
      reason: '名称必须 kebab-case',
    );
    expect(
      library.save(draft(triggers: ' ')).isSuccess,
      isFalse,
      reason: '技能必须带触发词，不允许始终适用',
    );
    expect(library.save(draft(body: '')).isSuccess, isFalse);
  });

  test('内容修订版本 +1 且旧正文进 history，无变化幂等', () {
    final library = SkillLibrary(directory: tmp, clock: () => now)..load();
    library.save(draft());

    // 同内容再存（仅状态不同）：不递增版本。
    final idem = library.save(
      draft().copyWith(status: SkillStatus.active, approvedAt: now),
    );
    expect((idem as Success<SkillManifest>).value.version, 1);

    // 内容变化：版本 2，旧版归档进 history/。
    final revised = library.save(draft(body: '新做法：先问篇幅再列四段'));
    expect((revised as Success<SkillManifest>).value.version, 2);
    expect(
      File(
        '${tmp.path}/suggest-report-outline/history/SKILL.v1.md',
      ).existsSync(),
      isTrue,
      reason: '旧版本必须留痕可找回',
    );
    expect(library.readBody('suggest-report-outline'), contains('新做法'));
  });

  test('三态流转：晋升可检索，退役不删文件且不再命中', () {
    final library = SkillLibrary(directory: tmp, clock: () => now)..load();
    library.save(draft());

    expect(library.match('帮我写周报'), isEmpty, reason: 'pending 不注入');

    library.setStatus('suggest-report-outline', SkillStatus.active);
    expect(library.match('帮我写周报大纲'), hasLength(1));
    expect(library.match('今天天气如何'), isEmpty, reason: '未命中触发词不注入');

    final retired = library.setStatus(
      'suggest-report-outline',
      SkillStatus.archived,
    );
    expect((retired as Success<SkillManifest>).value.archivedAt, isNotNull);
    expect(library.match('帮我写周报'), isEmpty);
    expect(
      File('${tmp.path}/suggest-report-outline/SKILL.md').existsSync(),
      isTrue,
      reason: '退役只改状态，不删文件',
    );
  });

  test('markUsed 计数落盘并在重开后保留', () {
    final library = SkillLibrary(directory: tmp, clock: () => now)..load();
    final saved = library.save(draft()) as Success<SkillManifest>;
    library.setStatus('suggest-report-outline', SkillStatus.active);
    library.markUsed([saved.value]);

    final reopened = SkillLibrary(directory: tmp, clock: () => now)..load();
    expect(reopened.byName('suggest-report-outline')!.useCount, 1);
  });

  test('超长描述与正文被兜底截断', () {
    final library = SkillLibrary(directory: tmp, clock: () => now)..load();
    final saved = library.save(
      draft(description: '长' * 200, body: '步' * 500),
    ) as Success<SkillManifest>;
    expect(saved.value.description.length, lessThanOrEqualTo(81));
    expect(saved.value.body.length, lessThanOrEqualTo(301));
  });

  test('索引损坏后按技能目录重建，三态可恢复', () {
    final library = SkillLibrary(directory: tmp, clock: () => now)..load();
    library.save(draft());
    library.setStatus('suggest-report-outline', SkillStatus.active);
    library.save(
      draft(
        name: 'avoid-table-replies',
        description: '不要用表格回复简短问题',
        triggers: '表格|table',
      ),
    );

    // 模拟索引损坏：写一坨非法 JSON。
    File('${tmp.path}/index.json').writeAsStringSync('{ broken');

    final rebuilt = SkillLibrary(directory: tmp, clock: () => now)..load();
    final outline = rebuilt.byName('suggest-report-outline');
    final avoidTable = rebuilt.byName('avoid-table-replies');
    expect(outline!.status, SkillStatus.active, reason: 'approvedAt 恢复生效态');
    expect(avoidTable!.status, SkillStatus.pending);
    expect(rebuilt.match('写个周报'), hasLength(1));
    // 重建结果应写回索引：再开一次不再触发重扫路径也成立。
    expect(
      jsonDecode(File('${tmp.path}/index.json').readAsStringSync()),
      isA<Map>(),
    );
  });

  test('渐进加载：readBody 按需读正文，readExtra 无文件返回 null', () {
    final library = SkillLibrary(directory: tmp, clock: () => now)..load();
    library.save(draft());

    // 新实例只装索引（body 已随 save 常驻；这里模拟索引只有元数据的场景：
    // 索引本身不含 body 时 readBody 会读盘）。
    final indexFile = File('${tmp.path}/index.json');
    final decoded = jsonDecode(indexFile.readAsStringSync()) as Map;
    for (final item in decoded['skills'] as List) {
      (item as Map).remove('body');
    }
    indexFile.writeAsStringSync(jsonEncode(decoded));

    final fresh = SkillLibrary(directory: tmp, clock: () => now)..load();
    expect(fresh.byName('suggest-report-outline')!.body, isEmpty);
    expect(fresh.readBody('suggest-report-outline'), contains('先确认'));
    expect(fresh.readExtra('suggest-report-outline'), isNull);
  });
}
