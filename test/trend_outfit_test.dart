import 'dart:io';

import 'package:dsh_pet_flutter/core/result.dart';
import 'package:dsh_pet_flutter/persona/appearance/trend_outfit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('trend_outfit_test');
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  group('LLM 输出解析（P2-3b）', () {
    test('合法 JSON：主题拼进 trend- 装扮名，hex 转成带 alpha 的颜色值', () {
      final proposal = parseTrendProposal(
        '{"theme":"冬日暖阳","main":"#E23E3E","trim":"F2C14E",'
        '"reason":"暖色围巾呼应初冬氛围"}',
        DateTime(2026, 1, 1, 12),
      );

      expect(proposal?.outfit, 'trend-冬日暖阳');
      expect(proposal?.theme, '冬日暖阳');
      expect(proposal?.main, 0xFFE23E3E);
      expect(proposal?.trim, 0xFFF2C14E);
      expect(proposal?.reason, '暖色围巾呼应初冬氛围');
    });

    test('JSON 外包话术也能解出（截首尾大括号）', () {
      final proposal = parseTrendProposal(
        '好的，这是我的提案：{"theme":"星夜","main":"6A3FA0",'
        '"trim":"#F2C14E","reason":"紫金搭配"} 请查收',
        DateTime(2026, 1, 1),
      );

      expect(proposal?.outfit, 'trend-星夜');
    });

    test('非法输入一律作废（安全侧返回 null）', () {
      final time = DateTime(2026, 1, 1);
      expect(parseTrendProposal('完全不是 JSON', time), isNull);
      expect(parseTrendProposal('[]', time), isNull);
      // 缺字段。
      expect(parseTrendProposal('{"theme":"x"}', time), isNull);
      // hex 不是 6 位。
      expect(
        parseTrendProposal(
          '{"theme":"x","reason":"y","main":"12345","trim":"FFFFFF"}',
          time,
        ),
        isNull,
      );
      // hex 非十六进制字符。
      expect(
        parseTrendProposal(
          '{"theme":"x","reason":"y","main":"GGGGGG","trim":"FFFFFF"}',
          time,
        ),
        isNull,
      );
      // reason 缺失。
      expect(
        parseTrendProposal('{"theme":"x","main":"123456","trim":"ABCDEF"}', time),
        isNull,
      );
    });

    test('主题与理由截断、控制字符剔除（主题会拼进装扮名）', () {
      final proposal = parseTrendProposal(
        '{"theme":"这是一个特别特别长的主题名字要被截断",'
        '"main":"123456","trim":"ABCDEF",'
        '"reason":"①②③${'理由' * 40}"}',
        DateTime(2026, 1, 1),
      );

      expect(proposal!.theme.length, 12);
      expect(proposal.outfit, 'trend-${proposal.theme}');
      expect(proposal.reason.length, 60);
      // 带换行的主题（JSON 转义，解码后是真实换行）：控制字符剔除后再拼名。
      final dirty = parseTrendProposal(
        '{"theme":"星\\n夜","main":"123456","trim":"ABCDEF","reason":"r"}',
        DateTime(2026, 1, 1),
      );
      expect(dirty?.outfit, 'trend-星夜');
    });
  });

  group('周键', () {
    test('同周同键、跨周翻篇', () {
      expect(trendWeekKey(DateTime(2026, 1, 3)), '2026-w0');
      expect(trendWeekKey(DateTime(2026, 1, 8)), '2026-w1');
      expect(trendWeekKey(DateTime(2026, 12, 30)), isNot('2026-w0'));
    });
  });

  group('治理状态存取', () {
    test('save/load 往返；空目录自动创建', () {
      final store = TrendOutfitStore(
        directory: Directory('${tmpDir.path}/profile'),
      );

      expect(store.load().lastProposedWeek, isNull);

      final saved = store.save(
        const TrendGate(lastProposedWeek: '2026-w1', rejectedUntilMs: 42),
      );
      expect(saved, isA<Success<void>>());

      final gate = store.load();
      expect(gate.lastProposedWeek, '2026-w1');
      expect(gate.rejectedUntilMs, 42);
    });

    test('文件损坏按「从未提案」继续（治理状态可丢）', () {
      final dir = Directory('${tmpDir.path}/profile')
        ..createSync(recursive: true);
      File('${dir.path}${Platform.pathSeparator}trend_outfit.json')
          .writeAsStringSync('not json');

      final gate = TrendOutfitStore(directory: dir).load();
      expect(gate.lastProposedWeek, isNull);
      expect(gate.rejectedUntilMs, isNull);
    });
  });
}
