import 'dart:convert';
import 'dart:io';

import 'package:dsh_pet_flutter/core/result.dart';
import 'package:dsh_pet_flutter/features/settings/sections/appearance_section.dart';
import 'package:dsh_pet_flutter/persona/appearance/appearance_evolution.dart';
import 'package:dsh_pet_flutter/persona/appearance/appearance_proposal.dart';
import 'package:dsh_pet_flutter/persona/appearance/appearance_state.dart';
import 'package:dsh_pet_flutter/persona/appearance/appearance_store.dart';
import 'package:dsh_pet_flutter/persona/appearance/outfit_policy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppearanceState', () {
    test('默认值稳定且体型缩放落在硬边界内', () {
      const state = AppearanceState();
      expect(state.revision, 0);
      expect(state.form, AppearanceForm.round);
      expect(state.palette, AppearancePalette.blue);
      expect(state.accessory, AppearanceAccessory.none);
      expect(state.motionSet, AppearanceMotionSet.calm);
      expect(state.expressionSet, AppearanceExpressionSet.soft);
      expect(state.frozen, isFalse);
      expect(state.bodyScale, 1.0);
    });

    test('JSON 往返不丢字段', () {
      final state = AppearanceState(
        revision: 3,
        form: AppearanceForm.chubby,
        bodyScale: 1.08,
        palette: AppearancePalette.orange,
        accessory: AppearanceAccessory.scarf,
        motionSet: AppearanceMotionSet.playful,
        expressionSet: AppearanceExpressionSet.bright,
        frozen: true,
        updatedAtMs: DateTime(2026, 11, 2, 10).millisecondsSinceEpoch,
      );
      final restored = AppearanceState.fromJson(
        jsonDecode(jsonEncode(state.toJson())) as Map<String, dynamic>,
      );
      expect(restored.signature, state.signature);
      expect(restored.revision, 3);
      expect(restored.updatedAt, state.updatedAt);
    });

    test('未知枚举与越界数值回落到安全值', () {
      final restored = AppearanceState.fromJson({
        'form': 'unknown',
        'bodyScale': 9.9,
        'accessory': 42,
        'updatedAt': 'not-a-date',
      });
      expect(restored.form, AppearanceForm.round);
      expect(restored.bodyScale, appearanceMaxBodyScale);
      expect(restored.accessory, AppearanceAccessory.none);
      expect(restored.updatedAtMs, 0);
    });

    test('构造时自动夹取体型缩放', () {
      final state = const AppearanceState().copyWith(bodyScale: 0.1);
      expect(state.bodyScale, appearanceMinBodyScale);
    });

    test('signature 随任一维度变化', () {
      const base = AppearanceState();
      expect(base.copyWith(palette: AppearancePalette.green).signature,
          isNot(base.signature));
      expect(base.copyWith(palette: AppearancePalette.green, form: AppearanceForm.tall)
          .signature, isNot(base.signature));
    });

    test('装扮默认居家，JSON 往返与非法值回落', () {
      const base = AppearanceState();
      expect(base.outfit, 'home');
      expect(base.outfitSource, AppearanceOutfitSource.builtin);

      final dressed = base.copyWith(
        outfit: 'winter',
        outfitSource: AppearanceOutfitSource.seasonal,
      );
      expect(dressed.outfit, 'winter');
      // 装扮不进人格推演的比较键（装饰层走独立轨道）。
      expect(dressed.signature, base.signature);

      final restored = AppearanceState.fromJson(
        jsonDecode(jsonEncode(dressed.toJson())) as Map<String, dynamic>,
      );
      expect(restored.outfit, 'winter');
      expect(restored.outfitSource, AppearanceOutfitSource.seasonal);

      // 白名单与 trend- 前缀之外的名字一律回落。
      expect(base.copyWith(outfit: 'super-cute').outfit, 'home');
      expect(base.copyWith(outfit: 'trend-2026-olympic').outfit,
          'trend-2026-olympic');
      expect(
        AppearanceState.fromJson({'outfit': 'weird', 'outfitSource': 'hacker'})
            .outfit,
        'home',
      );
      expect(
        AppearanceState.fromJson({'outfit': 'weird', 'outfitSource': 'hacker'})
            .outfitSource,
        AppearanceOutfitSource.builtin,
      );
    });
  });

  group('AppearanceStore', () {
    late Directory tmpDir;
    late AppearanceStore store;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('appearance_store_test');
      store = AppearanceStore(directory: tmpDir);
    });

    tearDown(() {
      tmpDir.deleteSync(recursive: true);
    });

    test('文件不存在时返回默认形象', () {
      final result = store.load();
      expect(result, isA<Success<AppearanceState>>());
      expect(result.valueOrNull!.signature, const AppearanceState().signature);
    });

    test('保存后可读回，并且原子写不残留临时文件', () {
      final state = const AppearanceState().copyWith(
        palette: AppearancePalette.green,
        revision: 1,
      );
      expect(store.save(state), isA<Success<void>>());
      expect(store.load().valueOrNull!.palette, AppearancePalette.green);
      expect(File('${tmpDir.path}/appearance.json.tmp').existsSync(), isFalse);
    });

    test('损坏的档案返回 Failure 而不是静默回退默认值', () {
      File('${tmpDir.path}/appearance.json').writeAsStringSync('{ broken');
      final result = store.load();
      expect(result, isA<Failure<AppearanceState>>());
      expect(result.failureOrNull!.code, 'appearance.malformed');
    });

    test('历史最多保留 appearanceHistoryLimit 条', () {
      for (var index = 0; index < appearanceHistoryLimit + 3; index++) {
        store.save(const AppearanceState().copyWith(revision: index));
      }
      final history = store.history();
      expect(history.length, appearanceHistoryLimit);
      expect(history.last.revision, appearanceHistoryLimit + 2);
    });

    test('回滚恢复到上一版并让修订号继续递增', () {
      final first = const AppearanceState().copyWith(
        palette: AppearancePalette.blue,
        revision: 1,
      );
      final second = const AppearanceState().copyWith(
        palette: AppearancePalette.orange,
        revision: 2,
      );
      store.save(first);
      store.save(second);

      final rolled = store.rollback();
      expect(rolled, isA<Success<AppearanceState>>());
      expect(rolled.valueOrNull!.palette, AppearancePalette.blue);
      expect(rolled.valueOrNull!.revision, 3);
      expect(store.load().valueOrNull!.palette, AppearancePalette.blue);
    });

    test('连续回滚不会拿到同一条历史', () {
      final first = const AppearanceState().copyWith(revision: 1, form: AppearanceForm.slim);
      final second = const AppearanceState().copyWith(revision: 2, form: AppearanceForm.round);
      final third = const AppearanceState().copyWith(revision: 3, form: AppearanceForm.tall);
      store.save(first);
      store.save(second);
      store.save(third);

      final rolledOnce = store.rollback();
      expect(rolledOnce.valueOrNull!.form, AppearanceForm.round);
      final rolledTwice = store.rollback();
      expect(rolledTwice.valueOrNull!.form, AppearanceForm.slim);
      expect(store.rollback().failureOrNull!.code, 'appearance.no-history');
    });

    test('没有历史时回滚返回明确原因', () {
      final result = store.rollback();
      expect(result.failureOrNull!.code, 'appearance.no-history');
    });

    test('形态提案可保存、读回与清除', () {
      expect(store.loadProposal().valueOrNull, isNull);

      final proposal = AppearanceProposal(
        id: 'form-round-chubby-1',
        targetForm: AppearanceForm.chubby,
        reason: '长期正反馈',
        createdAtMs: DateTime(2026, 11, 2, 10).millisecondsSinceEpoch,
      );
      expect(store.saveProposal(proposal), isA<Success<void>>());
      final loaded = store.loadProposal().valueOrNull!;
      expect(loaded.id, proposal.id);
      expect(loaded.targetForm, AppearanceForm.chubby);
      expect(loaded.createdAtMs, proposal.createdAtMs);

      expect(store.clearProposal(), isA<Success<void>>());
      expect(store.loadProposal().valueOrNull, isNull);
    });

    test('损坏的提案文件返回 Failure', () {
      File('${tmpDir.path}/appearance_proposal.json').writeAsStringSync('{ oops');
      final result = store.loadProposal();
      expect(result, isA<Failure<AppearanceProposal?>>());
      expect(result.failureOrNull!.code, 'appearance.proposal-malformed');
    });
  });

  group('AppearanceEvolution', () {
    const evolution = AppearanceEvolution();
    final now = DateTime(2026, 11, 2, 12);

    AppearanceSignals signals({
      double valence = 0,
      double arousal = 0.5,
      double intimacy = 0.2,
      double proactiveness = 0.4,
      int accepted = 0,
      int rejected = 0,
      int corrected = 0,
    }) => AppearanceSignals(
      valence: valence,
      arousal: arousal,
      intimacy: intimacy,
      proactiveness: proactiveness,
      acceptedCount: accepted,
      rejectedCount: rejected,
      correctedCount: corrected,
      now: now,
    );

    test('冻结时一律不动', () {
      final outcome = evolution.evolve(
        const AppearanceState(frozen: true),
        signals(accepted: 5, arousal: 0.9, valence: 0.8),
      );
      expect(outcome.changed, isFalse);
      expect(outcome.state.signature, const AppearanceState(frozen: true).signature);
      expect(outcome.reason, contains('冻结'));
    });

    test('冷却期内不演化', () {
      final recentlyChanged = AppearanceState(
        revision: 1,
        updatedAtMs: now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
      );
      final outcome = evolution.evolve(
        recentlyChanged,
        signals(accepted: 5, arousal: 0.9, valence: 0.8),
      );
      expect(outcome.changed, isFalse);
      expect(outcome.reason, contains('不足'));
    });

    test('信号不足时宁可不改', () {
      final outcome = evolution.evolve(
        const AppearanceState(),
        signals(accepted: 1, rejected: 1),
      );
      expect(outcome.changed, isFalse);
      expect(outcome.reason, contains('信号不足'));
    });

    test('单次最多改一个维度，并给出可读理由', () {
      final outcome = evolution.evolve(
        const AppearanceState(),
        signals(accepted: 3, rejected: 1, arousal: 0.9),
      );
      expect(outcome.changed, isTrue);
      expect(outcome.state.motionSet, AppearanceMotionSet.playful);
      expect(outcome.state.expressionSet, AppearanceExpressionSet.soft);
      expect(outcome.state.accessory, AppearanceAccessory.none);
      expect(outcome.state.revision, 1);
      expect(outcome.state.updatedAtMs, now.millisecondsSinceEpoch);
      expect(outcome.reason, contains('→'));
    });

    test('负反馈优先让动作组安静下来', () {
      final outcome = evolution.evolve(
        const AppearanceState(motionSet: AppearanceMotionSet.playful),
        signals(accepted: 1, rejected: 2, arousal: 0.5),
      );
      expect(outcome.state.motionSet, AppearanceMotionSet.calm);
    });

    test('亲密度足够后配饰逐级递进', () {
      final outcome = evolution.evolve(
        const AppearanceState(
          motionSet: AppearanceMotionSet.calm,
          expressionSet: AppearanceExpressionSet.cool,
        ),
        signals(accepted: 2, rejected: 1, intimacy: 0.8),
      );
      expect(outcome.state.accessory, AppearanceAccessory.scarf);
    });

    test('体型缩放到上限后不再越界', () {
      final atMax = AppearanceState(
        motionSet: AppearanceMotionSet.calm,
        expressionSet: AppearanceExpressionSet.cool,
        accessory: AppearanceAccessory.hat,
        bodyScale: appearanceMaxBodyScale,
        revision: 1,
        updatedAtMs: now.subtract(const Duration(hours: 13)).millisecondsSinceEpoch,
      );
      final outcome = evolution.evolve(
        atMax,
        signals(accepted: 3, rejected: 1, proactiveness: 0.9),
      );
      expect(outcome.changed, isFalse);
      expect(outcome.state.bodyScale, appearanceMaxBodyScale);
      expect(outcome.reason, contains('边界'));
    });

    test('同等输入必得同等输出', () {
      final input = signals(accepted: 4, arousal: 0.8, valence: 0.6, intimacy: 0.7);
      final a = evolution.evolve(const AppearanceState(), input);
      final b = evolution.evolve(const AppearanceState(), input);
      expect(a.state.signature, b.state.signature);
      expect(a.reason, b.reason);
    });

    test('形态不再自动改变，只产出待确认提案', () {
      final outline = AppearanceState(
        form: AppearanceForm.round,
        motionSet: AppearanceMotionSet.lively,
        expressionSet: AppearanceExpressionSet.bright,
        accessory: AppearanceAccessory.hat,
        bodyScale: appearanceMaxBodyScale,
        revision: 1,
        updatedAtMs: now.subtract(const Duration(hours: 13)).millisecondsSinceEpoch,
      );
      final outcome = evolution.evolve(
        outline,
        signals(
          accepted: 4,
          rejected: 1,
          arousal: 0.8,
          valence: 0.5,
          intimacy: 0.7,
          proactiveness: 0.9,
        ),
      );
      expect(outcome.changed, isFalse);
      expect(outcome.state.form, AppearanceForm.round);
      expect(outcome.proposal, isNotNull);
      expect(outcome.proposal!.targetForm, AppearanceForm.chubby);
      expect(outcome.reason, contains('确认'));
    });

    test('形态已到末档时不再提案', () {
      final lastForm = AppearanceState(
        form: AppearanceForm.tall,
        motionSet: AppearanceMotionSet.lively,
        expressionSet: AppearanceExpressionSet.bright,
        accessory: AppearanceAccessory.hat,
        bodyScale: appearanceMaxBodyScale,
        revision: 1,
        updatedAtMs: now.subtract(const Duration(hours: 13)).millisecondsSinceEpoch,
      );
      final outcome = evolution.evolve(
        lastForm,
        signals(
          accepted: 4,
          rejected: 1,
          arousal: 0.8,
          valence: 0.5,
          intimacy: 0.7,
          proactiveness: 0.9,
        ),
      );
      expect(outcome.changed, isFalse);
      expect(outcome.proposal, isNull);
      expect(outcome.reason, contains('边界'));
    });
  });

  group('AppearanceSection', () {
    testWidgets('预览可渲染，操作按钮回调参数正确', (tester) async {
      var evolved = 0;
      var rolledBack = 0;
      bool? frozen;
      const state = AppearanceState(
        form: AppearanceForm.chubby,
        palette: AppearancePalette.orange,
        accessory: AppearanceAccessory.scarf,
        expressionSet: AppearanceExpressionSet.bright,
        bodyScale: 1.1,
        revision: 2,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: AppearanceSection(
              state: state,
              reason: '动作组 calm → playful（依据：正反馈偏多，净强度 0.50）',
              hint: '',
              onEvolve: () => evolved++,
              onRollback: () => rolledBack++,
              onFreeze: (value) => frozen = value,
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('推演一次'), findsOneWidget);
      expect(find.text('回滚上一版'), findsOneWidget);
      expect(find.text('冻结'), findsOneWidget);

      await tester.tap(find.text('推演一次'));
      await tester.tap(find.text('回滚上一版'));
      await tester.tap(find.text('冻结'));
      expect(evolved, 1);
      expect(rolledBack, 1);
      expect(frozen, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('冻结状态显示解冻入口', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: AppearanceSection(
              state: const AppearanceState(frozen: true, revision: 4),
              reason: '形象已冻结，自动演化暂停',
              hint: '已冻结自动演化',
              onEvolve: () {},
              onRollback: () {},
              onFreeze: (_) {},
            ),
          ),
        ),
      );
      expect(find.text('解冻'), findsOneWidget);
      expect(find.text('已冻结自动演化'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
    testWidgets('有形态提案时展示接受/拒绝入口', (tester) async {
      var accepted = 0;
      var rejected = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: AppearanceSection(
              state: const AppearanceState(revision: 1),
              reason: '形态建议：round → chubby（依据：长期正反馈；确认后才生效）',
              hint: '',
              proposal: AppearanceProposal(
                id: 'form-round-chubby-1',
                targetForm: AppearanceForm.chubby,
                reason: '长期正反馈、唤醒度较高',
                createdAtMs: DateTime(2026, 11, 2).millisecondsSinceEpoch,
              ),
              onAcceptProposal: () => accepted++,
              onRejectProposal: () => rejected++,
              onEvolve: () {},
              onRollback: () {},
              onFreeze: (_) {},
            ),
          ),
        ),
      );

      expect(find.textContaining('形态提案：圆润 → 敦实'), findsOneWidget);
      await tester.tap(find.text('接受'));
      await tester.tap(find.text('拒绝'));
      expect(accepted, 1);
      expect(rejected, 1);
      expect(tester.takeException(), isNull);
    });
  });

  group('情境换装（P2-1）', () {
    AppearanceSignals signalsAt(DateTime now, {String? weather}) =>
        AppearanceSignals(
          valence: 0,
          arousal: 0,
          intimacy: 0,
          proactiveness: 0,
          acceptedCount: 0,
          rejectedCount: 0,
          correctedCount: 0,
          now: now,
          weather: weather,
        );

    test('四季按节气近似日切换', () {
      // 立春 2/4、立夏 5/6、立秋 8/7、立冬 11/7，跨年段（冬）两头覆盖。
      expect(seasonOf(DateTime(2026, 2, 3)), AppearanceSeason.winter);
      expect(seasonOf(DateTime(2026, 2, 5)), AppearanceSeason.spring);
      expect(seasonOf(DateTime(2026, 5, 5)), AppearanceSeason.spring);
      expect(seasonOf(DateTime(2026, 5, 7)), AppearanceSeason.summer);
      expect(seasonOf(DateTime(2026, 8, 6)), AppearanceSeason.summer);
      expect(seasonOf(DateTime(2026, 8, 8)), AppearanceSeason.autumn);
      expect(seasonOf(DateTime(2026, 11, 6)), AppearanceSeason.autumn);
      expect(seasonOf(DateTime(2026, 11, 8)), AppearanceSeason.winter);
      expect(seasonOf(DateTime(2026, 1, 1)), AppearanceSeason.winter);
      expect(seasonOf(DateTime(2026, 12, 31)), AppearanceSeason.winter);
      expect(solarTermOf(DateTime(2026, 11, 4)), '霜降');
      expect(solarTermOf(DateTime(2026, 11, 8)), '立冬');
    });

    test('节令窗口：农历查表与公历固定日，窗口外返回空', () {
      // 2026 中秋 9/25，窗口 9/22-9/28；2027 春节 2/6。
      expect(festivalOf(DateTime(2026, 9, 25)), 'midautumn');
      expect(festivalOf(DateTime(2026, 9, 22)), 'midautumn');
      expect(festivalOf(DateTime(2026, 9, 28)), 'midautumn');
      expect(festivalOf(DateTime(2026, 9, 21)), isNull);
      expect(festivalOf(DateTime(2026, 9, 29)), isNull);
      expect(festivalOf(DateTime(2027, 2, 6)), 'newyear');
      expect(festivalOf(DateTime(2026, 10, 31)), 'halloween');
      expect(festivalOf(DateTime(2026, 12, 25)), 'christmas');
      expect(festivalOf(DateTime(2026, 11, 4)), isNull);
      // 查表范围外的年份：安全侧返回空，不换装。
      expect(festivalOf(DateTime(2040, 9, 25)), isNull);
    });

    test('季节轨道：跨立冬自动换冬装，已穿则不动', () {
      const home = AppearanceState();
      final toWinter = decideOutfit(home, signalsAt(DateTime(2026, 11, 8)));
      expect(toWinter.changed, isTrue);
      expect(toWinter.outfit, 'winter');
      expect(toWinter.source, AppearanceOutfitSource.seasonal);

      final already = decideOutfit(
        home.copyWith(
          outfit: 'winter',
          outfitSource: AppearanceOutfitSource.seasonal,
        ),
        signalsAt(DateTime(2026, 11, 8)),
      );
      expect(already.changed, isFalse);
      expect(already.outfit, 'winter');
    });

    test('优先级：节令 > 天气 > 季节', () {
      // 12/25 圣诞窗口（此时也是冬天）：节令盖过季节与天气。
      final festive = decideOutfit(
        const AppearanceState(),
        signalsAt(DateTime(2026, 12, 25), weather: 'rain'),
      );
      expect(festive.outfit, 'christmas');
      expect(festive.source, AppearanceOutfitSource.festive);

      // 非节令日：已确认的天气装扮盖过季节。
      final rainy = decideOutfit(
        const AppearanceState(),
        signalsAt(DateTime(2026, 11, 10), weather: 'rain'),
      );
      expect(rainy.outfit, 'rain');
      expect(rainy.source, AppearanceOutfitSource.weather);

      // 天气装扮只在传入当天有效：次日不带 weather 即回季节轨道。
      final backToSeason = decideOutfit(
        const AppearanceState().copyWith(
          outfit: 'rain',
          outfitSource: AppearanceOutfitSource.weather,
        ),
        signalsAt(DateTime(2026, 11, 11)),
      );
      expect(backToSeason.outfit, 'winter');
      expect(backToSeason.source, AppearanceOutfitSource.seasonal);

      // 节令装扮在窗口内不被季节抢回，窗口结束才回季节轨道。
      final midFestival = decideOutfit(
        const AppearanceState().copyWith(
          outfit: 'midautumn',
          outfitSource: AppearanceOutfitSource.festive,
        ),
        signalsAt(DateTime(2026, 9, 26)),
      );
      expect(midFestival.changed, isFalse);
      final afterFestival = decideOutfit(
        const AppearanceState().copyWith(
          outfit: 'midautumn',
          outfitSource: AppearanceOutfitSource.festive,
        ),
        signalsAt(DateTime(2026, 9, 30)),
      );
      expect(afterFestival.outfit, 'autumn');
    });

    test('冻结优先与时钟回拨保持现状', () {
      final frozen = decideOutfit(
        const AppearanceState().copyWith(frozen: true),
        signalsAt(DateTime(2026, 11, 8)),
      );
      expect(frozen.changed, isFalse);
      expect(frozen.outfit, 'home');
      expect(frozen.reason, contains('冻结'));

      // 日期信号早于上次形象变化：视为时钟回拨，不切换。
      final clockSkew = decideOutfit(
        const AppearanceState().copyWith(
          updatedAtMs: DateTime(2026, 11, 8, 12).millisecondsSinceEpoch,
        ),
        signalsAt(DateTime(2026, 11, 8, 11)),
      );
      expect(clockSkew.changed, isFalse);
      expect(clockSkew.reason, contains('时钟回拨'));
    });
  });
}
